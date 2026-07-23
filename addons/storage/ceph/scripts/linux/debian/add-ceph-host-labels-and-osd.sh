#!/bin/bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT
#
# add-ceph-host-labels-and-osd.sh  -  Debian13 variant
#
# Labels a Ceph host with osd/mgr/mds and optionally provisions an OSD on a target device.
#
# Expected usage:
#   ./add-ceph-host-labels-and-osd.sh <host-name> [device] [cluster-fsid]
#
# Examples:
#   ./add-ceph-host-labels-and-osd.sh deb12cephinstallationusingscript
#   ./add-ceph-host-labels-and-osd.sh deb12cephinstallationusingscript /dev/sdb
#   ./add-ceph-host-labels-and-osd.sh deb12cephinstallationusingscript /dev/sdb c5664782-8433-11f1-8378-00155d130f2b
#
# Notes:
# - This script does NOT wipe the disk. It asks cephadm/ceph-volume to consume the device.
# - If you need a typo-compatible label for legacy automation, set ADD_MSD_LABEL=1 to add label "msd" too.

set -uo pipefail

HOST_NAME="${1:-}"
DEVICE="${2:-}"
CLUSTER_FSID="${3:-}"
ADD_MSD_LABEL="${ADD_MSD_LABEL:-0}"

log_info() {
    echo "[CephOsdAdd] $1"
}

log_error() {
    echo "[CephOsdAdd] ERROR: $1" >&2
}

if [ -z "$HOST_NAME" ]; then
    log_error "Usage: add-ceph-host-labels-and-osd.sh <host-name> [device] [cluster-fsid]"
    exit 1
fi

LABELS_ONLY=0
if [ -z "$DEVICE" ]; then
    LABELS_ONLY=1
else
    if [ ! -b "$DEVICE" ]; then
        log_error "Device '$DEVICE' is not a block device on this host."
        exit 1
    fi

    DEV_TYPE="$(lsblk -dn -o TYPE "$DEVICE" 2>/dev/null | head -n1 | tr -d '[:space:]')"
    if [ "$DEV_TYPE" != "disk" ]; then
        log_error "Device '$DEVICE' has type '$DEV_TYPE'. Pass a whole disk (for example /dev/sdb), not a partition."
        exit 1
    fi
fi

CEPHADM_BIN=""
if command -v cephadm >/dev/null 2>&1; then
    CEPHADM_BIN="$(command -v cephadm)"
elif [ -x "$(pwd)/cephadm" ]; then
    CEPHADM_BIN="$(pwd)/cephadm"
fi

if [ -z "$CEPHADM_BIN" ]; then
    for candidate in /usr/sbin/cephadm /usr/bin/cephadm /sbin/cephadm; do
        if [ -x "$candidate" ]; then
            CEPHADM_BIN="$candidate"
            break
        fi
    done
fi

if [ -z "$CEPHADM_BIN" ]; then
    log_error "cephadm binary not found on this host."
    exit 1
fi

CEPHADM_SHELL=(sudo "$CEPHADM_BIN" shell)
if [ -n "$CLUSTER_FSID" ]; then
    CEPHADM_SHELL+=(--fsid "$CLUSTER_FSID")
fi

run_ceph_cmd() {
    "${CEPHADM_SHELL[@]}" -- "$@"
}

log_info "Using cephadm binary: $CEPHADM_BIN"
if [ -n "$CLUSTER_FSID" ]; then
    log_info "Targeting cluster fsid: $CLUSTER_FSID"
fi

log_info "Ensuring host '$HOST_NAME' exists in ceph orch inventory"
if ! run_ceph_cmd ceph orch host ls 2>/dev/null | grep -Eq "(^|[[:space:]])${HOST_NAME}([[:space:]]|$)"; then
    log_error "Host '$HOST_NAME' is not present in ceph orch host list. Add/register host first."
    exit 1
fi

#LABELS=(osd mgr mds)
LABELS=(osd)
if [ "$ADD_MSD_LABEL" = "1" ]; then
    LABELS+=(msd)
fi

for label in "${LABELS[@]}"; do
    log_info "Adding host label '$label' to '$HOST_NAME'"
    label_output="$(run_ceph_cmd ceph orch host label add "$HOST_NAME" "$label" 2>&1)"
    label_rc=$?

    if [ $label_rc -eq 0 ]; then
        log_info "Label '$label' added on '$HOST_NAME'"
        continue
    fi

    if echo "$label_output" | grep -Eiq 'already|exists'; then
        log_info "Label '$label' already present on '$HOST_NAME'"
        continue
    fi

    log_error "Failed to add label '$label' on '$HOST_NAME': $label_output"
    exit 1

done

if [ "$LABELS_ONLY" = "1" ]; then
    log_info "Labels applied on '$HOST_NAME'. No device argument provided, skipping OSD creation."
    exit 0
fi

log_info "Adding OSD for host '$HOST_NAME' on device '$DEVICE'"

# Idempotency: if the target device is already consumed by a Ceph OSD (has a 'ceph--*' LVM child),
# there is nothing to do. This makes re-enabling the addon safe instead of failing on 'device in use'.
if lsblk -no NAME "$DEVICE" 2>/dev/null | grep -q 'ceph--'; then
    log_info "Device '$DEVICE' already backs a Ceph OSD; skipping provisioning."
    exit 0
fi

# Resolve the cluster fsid (required by the direct-provisioning fallback below).
if [ -z "$CLUSTER_FSID" ]; then
    CLUSTER_FSID="$(run_ceph_cmd ceph fsid 2>/dev/null | tr -d '[:space:]')"
fi

# Current number of OSDs in the cluster (used to detect whether provisioning actually happened).
LAST_OSD_COUNT=0
osd_count() {
    run_ceph_cmd ceph osd stat -f json 2>/dev/null | grep -oE '"num_osds":[0-9]+' | grep -oE '[0-9]+' | head -n1
}

# Wait up to $1 seconds for the OSD count to rise above baseline $2. Sets LAST_OSD_COUNT.
wait_for_osd_increase() {
    local timeout="$1" baseline="$2" now="" waited=0
    while [ "$waited" -lt "$timeout" ]; do
        sleep 5
        waited=$((waited + 5))
        now="$(osd_count)"; now="${now:-0}"
        if [ "$now" -gt "$baseline" ]; then
            LAST_OSD_COUNT="$now"
            return 0
        fi
    done
    LAST_OSD_COUNT="${now:-$baseline}"
    return 1
}

# Directly provision an OSD on $DEVICE using 'cephadm ceph-volume' + 'cephadm deploy', bypassing the
# orchestrator. Needed because some Ceph container images (observed with Tentacle/v20) accept
# 'ceph orch daemon add osd' and register the OSD service spec but never invoke ceph-volume, so the
# cluster ends up with zero OSDs. This must run on a node that hosts a MON (so the mon config and
# bootstrap-osd keyring are locally available) - true for the K2s single-node Ceph layout where the
# bootstrap node is also the OSD host.
provision_osd_directly() {
    if [ -z "$CLUSTER_FSID" ]; then
        log_error "Cannot provision OSD directly: cluster fsid is unknown."
        return 1
    fi

    local mon_config
    mon_config="$(sudo bash -c "ls /var/lib/ceph/$CLUSTER_FSID/mon.*/config 2>/dev/null | head -n1")"
    if [ -z "$mon_config" ]; then
        log_error "Cannot provision OSD directly: no local MON config under /var/lib/ceph/$CLUSTER_FSID (this node is not a MON host)."
        return 1
    fi

    # Use the exact Ceph image the cluster is already running so 'cephadm deploy'/'ceph-volume' do
    # not reach for a tag that is absent on an air-gapped node.
    local ceph_image image_arg=()
    ceph_image="$(sudo podman ps --filter name=ceph- --format '{{.Image}}' 2>/dev/null | grep -E 'ceph/ceph' | head -n1)"
    if [ -n "$ceph_image" ]; then
        image_arg=(--image "$ceph_image")
        log_info "Using running Ceph image for provisioning: $ceph_image"
    fi

    local keyring="/tmp/k2s-ceph-bootstrap-osd.$$.keyring"
    if ! run_ceph_cmd ceph auth get client.bootstrap-osd 2>/dev/null | sudo tee "$keyring" >/dev/null; then
        log_error "Failed to export the bootstrap-osd keyring."
        sudo rm -f "$keyring"
        return 1
    fi

    log_info "Provisioning OSD directly on '$DEVICE' via ceph-volume (mon config: $mon_config)"
    if ! sudo "$CEPHADM_BIN" "${image_arg[@]}" ceph-volume --config "$mon_config" --keyring "$keyring" -- lvm prepare --data "$DEVICE" >/dev/null 2>&1; then
        log_error "ceph-volume lvm prepare failed for '$DEVICE'."
        sudo rm -f "$keyring"
        return 1
    fi

    # Read back the freshly prepared OSD id + fsid for exactly this device.
    local lvm_txt osd_id osd_fsid
    lvm_txt="$(sudo "$CEPHADM_BIN" "${image_arg[@]}" ceph-volume --config "$mon_config" --keyring "$keyring" -- lvm list "$DEVICE" 2>/dev/null)"
    sudo rm -f "$keyring"
    osd_id="$(echo "$lvm_txt" | grep -E '^[[:space:]]*osd id' | awk '{print $NF}' | head -n1)"
    osd_fsid="$(echo "$lvm_txt" | grep -E '^[[:space:]]*osd fsid' | awk '{print $NF}' | head -n1)"
    if [ -z "$osd_id" ] || [ -z "$osd_fsid" ]; then
        log_error "Could not determine the prepared OSD id/fsid for '$DEVICE'."
        return 1
    fi
    log_info "Prepared osd.$osd_id (osd fsid $osd_fsid) on '$DEVICE'"

    # Deploy the OSD daemon. The first start fails on these images because cephadm does not write the
    # daemon 'config' file that unit.run bind-mounts as /etc/ceph/ceph.conf; seed it from the mon
    # config and (re)start the unit.
    log_info "Deploying OSD daemon osd.$osd_id"
    sudo "$CEPHADM_BIN" "${image_arg[@]}" deploy --name "osd.$osd_id" --fsid "$CLUSTER_FSID" --osd-fsid "$osd_fsid" >/dev/null 2>&1 || true

    local osd_dir="/var/lib/ceph/$CLUSTER_FSID/osd.$osd_id"
    if [ ! -f "$osd_dir/config" ]; then
        if ! sudo cp "$mon_config" "$osd_dir/config"; then
            log_error "Failed to seed OSD daemon config at $osd_dir/config."
            return 1
        fi
        sudo chown 167:167 "$osd_dir/config"
        sudo chmod 0600 "$osd_dir/config"
        log_info "Seeded OSD daemon config at $osd_dir/config"
    fi

    sudo systemctl reset-failed "ceph-$CLUSTER_FSID@osd.$osd_id" 2>/dev/null || true
    if ! sudo systemctl restart "ceph-$CLUSTER_FSID@osd.$osd_id"; then
        log_error "Failed to (re)start OSD daemon unit ceph-$CLUSTER_FSID@osd.$osd_id."
        return 1
    fi
    log_info "OSD daemon ceph-$CLUSTER_FSID@osd.$osd_id started"
    return 0
}

OSD_COUNT_BEFORE="$(osd_count)"
OSD_COUNT_BEFORE="${OSD_COUNT_BEFORE:-0}"

# Preferred path: let the orchestrator provision the OSD.
log_info "Requesting OSD via orchestrator: ceph orch daemon add osd ${HOST_NAME}:${DEVICE}"
run_ceph_cmd ceph orch daemon add osd "${HOST_NAME}:${DEVICE}" >/dev/null 2>&1 || true

log_info "Waiting for the orchestrator to provision the OSD (up to 90s)..."
if wait_for_osd_increase 90 "$OSD_COUNT_BEFORE"; then
    log_info "OSD provisioned by orchestrator (osd count: $OSD_COUNT_BEFORE -> $LAST_OSD_COUNT)"
else
    log_info "Orchestrator did not provision an OSD (still $OSD_COUNT_BEFORE); falling back to direct ceph-volume provisioning."
    # Drop the registered-but-inert OSD service spec so it does not linger.
    run_ceph_cmd ceph orch rm osd.default --force >/dev/null 2>&1 || true
    if ! provision_osd_directly; then
        log_error "Failed to provision OSD on '${HOST_NAME}:${DEVICE}'."
        log_error "Inspect with: sudo $CEPHADM_BIN shell -- ceph orch device ls '$HOST_NAME'; ceph -W cephadm"
        exit 1
    fi
    if ! wait_for_osd_increase 90 "$OSD_COUNT_BEFORE"; then
        log_error "OSD daemon did not come up after direct provisioning on '${HOST_NAME}:${DEVICE}'."
        exit 1
    fi
    log_info "OSD provisioned directly (osd count: $OSD_COUNT_BEFORE -> $LAST_OSD_COUNT)"
fi

log_info "Done. Check progress with: sudo $CEPHADM_BIN shell -- ceph -s and ceph orch ps --daemon_type osd"
exit 0
