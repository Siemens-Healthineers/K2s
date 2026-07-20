#!/bin/bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT
#
# add-ceph-host-labels-and-osd.sh  -  Debian (12/13) variant
#
# Labels a Ceph host with osd/mgr/mds and provisions an OSD on a target device.
#
# Expected usage:
#   ./add-ceph-host-labels-and-osd.sh <host-name> <device> [cluster-fsid]
#
# Examples:
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

if [ -z "$HOST_NAME" ] || [ -z "$DEVICE" ]; then
    log_error "Usage: add-ceph-host-labels-and-osd.sh <host-name> <device> [cluster-fsid]"
    exit 1
fi

if [ ! -b "$DEVICE" ]; then
    log_error "Device '$DEVICE' is not a block device on this host."
    exit 1
fi

DEV_TYPE="$(lsblk -dn -o TYPE "$DEVICE" 2>/dev/null | head -n1 | tr -d '[:space:]')"
if [ "$DEV_TYPE" != "disk" ]; then
    log_error "Device '$DEVICE' has type '$DEV_TYPE'. Pass a whole disk (for example /dev/sdb), not a partition."
    exit 1
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

LABELS=(osd mgr mds)
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

log_info "Adding OSD for host '$HOST_NAME' on device '$DEVICE'"
osd_output="$(run_ceph_cmd ceph orch daemon add osd "${HOST_NAME}:${DEVICE}" 2>&1)"
osd_rc=$?

if [ $osd_rc -ne 0 ]; then
    log_error "Failed to add OSD on '${HOST_NAME}:${DEVICE}': $osd_output"
    exit 1
fi

log_info "OSD add command accepted: $osd_output"
log_info "Done. Check progress with: sudo $CEPHADM_BIN shell -- ceph -s and ceph orch ps --daemon_type osd"
exit 0
