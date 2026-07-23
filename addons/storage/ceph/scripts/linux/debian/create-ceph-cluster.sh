#!/bin/bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT
#
# create-ceph-cluster.sh  -  Debian 13 variant
#
# Bootstraps a new Ceph cluster on this node using cephadm and creates the
# CephFS filesystem/pool used by the storage/ceph addon CSI installation.
#
# Invoked remotely by addons/storage/ceph/scripts/linux/debian/New-CephCluster.ps1
# via Invoke-RemoteScript when ceph-config.json requests a new cluster
# (clusterMode != 'existing', clusterDistribution = 'debian13').
#
# Arguments:
#   $1 - Optional HTTP/HTTPS proxy URL
#   $2 - Ceph image reference from storage addon additionalImages
#   $3 - CephFS filesystem name to create (from ceph-config.json 'cephfsFilesystem')
#   $4 - SSH user for cephadm host management (defaults to 'remote')
#   $5 - Optional osd_crush_chooseleaf_type value
#   $6 - Optional mon daemon count
#   $7 - Optional mgr daemon count
#   $8 - Optional mds daemon count for the CephFS filesystem

PROXY="${1:-}"
CEPH_IMAGE_INPUT="${2:-}"
CEPH_FS_NAME="${3:-cephfs}"
CEPH_SSH_USER="${4:-remote}"
OSD_CRUSH_CHOOSELEAF_TYPE="${5:-}"
MON_COUNT="${6:-}"
MGR_COUNT="${7:-}"
MDS_COUNT="${8:-}"

log_info() {
    echo "[CephNew] $1"
}

log_error() {
    echo "[CephNew] ERROR: $1" >&2
}

log_info "Starting new Ceph cluster bootstrap on Debian"

cleanup_proxy_config() {
    if [ -n "$PROXY" ]; then
        sudo rm -f /etc/apt/apt.conf.d/95k2s-proxy
    fi
}

trap cleanup_proxy_config EXIT

# APT sandbox config
echo 'APT::Sandbox::User "root";' | sudo tee /etc/apt/apt.conf.d/10sandbox-for-k2s > /dev/null

# Configure apt proxy if provided (ensures apt-get uses the same proxy path)
if [ -n "$PROXY" ]; then
    log_info "Configuring apt proxy: $PROXY"
    printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "$PROXY" "$PROXY" | sudo tee /etc/apt/apt.conf.d/95k2s-proxy > /dev/null
fi

OFFLINE_PKG_DIR="$HOME/.storage"
if [ -d "$OFFLINE_PKG_DIR" ]; then
    offline_debs="$(find "$OFFLINE_PKG_DIR" -type f -name '*.deb' 2>/dev/null)"
    if [ -n "$offline_debs" ]; then
        log_info "Installing offline debian packages from $OFFLINE_PKG_DIR"
        # shellcheck disable=SC2086
        sudo dpkg -i $offline_debs 2>/dev/null || true
        sudo DEBIAN_FRONTEND=noninteractive apt-get -f install -y --no-download 2>/dev/null || true
    fi
fi

if ! command -v podman >/dev/null 2>&1; then
    log_info "podman not found, installing it via apt-get"
    sudo apt-get update
    if ! sudo apt-get install -y podman; then
        log_error "Failed to install podman (required by cephadm)"
        exit 1
    fi
fi
log_info "Using container engine: $(command -v podman)"

# Use the Ceph image from the storage addon manifest for bootstrapping
CEPH_IMAGE="$CEPH_IMAGE_INPUT"
log_info "Using Ceph image from storage addon manifest: $CEPH_IMAGE"

if sudo podman image exists "$CEPH_IMAGE" 2>/dev/null; then
    log_info "Ceph image '$CEPH_IMAGE' already present locally (e.g. loaded during offline artifact import); skipping pull"
elif [ -n "$PROXY" ]; then
    log_info "Pulling Ceph image via proxy for quay.io access: $CEPH_IMAGE"
    if ! sudo env HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY" podman pull "$CEPH_IMAGE"; then
        log_error "Failed to pull Ceph image '$CEPH_IMAGE' with proxy"
        exit 1
    fi
else
    log_info "Pulling Ceph image without proxy: $CEPH_IMAGE"
    if ! sudo podman pull "$CEPH_IMAGE"; then
        log_error "Failed to pull Ceph image '$CEPH_IMAGE'"
        exit 1
    fi
fi

CEPH_VERSION_STRING="$(sudo podman run --rm --entrypoint ceph "$CEPH_IMAGE" --version 2>/dev/null)"
CEPH_VERSION="$(echo "$CEPH_VERSION_STRING" | sed -E 's/^ceph version ([0-9.]+) .*/\1/')"
CEPH_RELEASE="$(echo "$CEPH_VERSION_STRING" | sed -E 's/^.*\) ([[:alpha:]]+) \(stable\).*/\1/')"

if [ -z "$CEPH_VERSION" ] || [ "$CEPH_VERSION" = "$CEPH_VERSION_STRING" ]; then
    log_error "Could not determine Ceph version from image '$CEPH_IMAGE' (got: '$CEPH_VERSION_STRING')"
    exit 1
fi
if [ -z "$CEPH_RELEASE" ] || [ "$CEPH_RELEASE" = "$CEPH_VERSION_STRING" ]; then
    log_error "Could not determine Ceph release codename from image '$CEPH_IMAGE' (got: '$CEPH_VERSION_STRING')"
    exit 1
fi
log_info "Detected Ceph version '$CEPH_VERSION' (release codename '$CEPH_RELEASE') from image"

is_valid_cephadm() {
    head -n1 "$1" 2>/dev/null | grep -qE '^#!.*python'
}

download_cephadm() {
    local url="$1"
    rm -f cephadm
    curl -x "$PROXY" --fail --silent --show-error --remote-name --location "$url" || return 1
    if ! is_valid_cephadm cephadm; then
        log_error "Downloaded file from '$url' is not the cephadm script (likely an HTTP error page)."
        rm -f cephadm
        return 1
    fi
    return 0
}

# Obtain the cephadm bootstrap binary. Prefer the binary staged offline into
# ~/.storage/cephadm during 'k2s addons import' so air-gapped installs never depend on
# download.ceph.com. Only fall back to downloading when no valid offline copy is present.
OFFLINE_CEPHADM="$HOME/.storage/cephadm"
if [ -f "$OFFLINE_CEPHADM" ] && is_valid_cephadm "$OFFLINE_CEPHADM"; then
    log_info "Using offline cephadm bootstrap binary staged at $OFFLINE_CEPHADM"
    cp "$OFFLINE_CEPHADM" ./cephadm
elif download_cephadm "https://download.ceph.com/rpm-$CEPH_VERSION/el9/noarch/cephadm"; then
    log_info "Downloaded cephadm bootstrap binary for version '$CEPH_VERSION'"
elif download_cephadm "https://download.ceph.com/rpm-$CEPH_RELEASE/el9/noarch/cephadm"; then
    log_info "Downloaded cephadm bootstrap binary for release '$CEPH_RELEASE'"
else
    log_error "Failed to obtain a valid cephadm bootstrap binary (offline copy at $OFFLINE_CEPHADM missing/invalid and download from download.ceph.com failed for version '$CEPH_VERSION' and release '$CEPH_RELEASE')."
    exit 1
fi

# Make the cephadm binary executable
sudo chmod +x cephadm

# Install cephadm onto PATH so bare 'cephadm' invocations resolve later in this script and
# in New-CephCluster.ps1 ('sudo cephadm shell ...'), even when the online 'cephadm install'
# step below cannot reach the Ceph package repositories (offline / air-gapped).
sudo install -m 0755 ./cephadm /usr/local/bin/cephadm

if ! dpkg -s gnupg >/dev/null 2>&1; then
    sudo apt-get install -y gnupg
fi
sudo rm -f /etc/apt/trusted.gpg.d/ceph.asc

CEPHADM_PROXY_ENV=()
if [ -n "$PROXY" ]; then
    CEPHADM_PROXY_ENV=(http_proxy="$PROXY" https_proxy="$PROXY" HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY")
fi

sudo env "${CEPHADM_PROXY_ENV[@]}" ./cephadm add-repo --release "$CEPH_RELEASE" || \
    log_info "add-repo failed (continuing; host-side ceph CLI may be unavailable)"

sudo env "${CEPHADM_PROXY_ENV[@]}" ./cephadm install || \
    log_info "cephadm install failed (continuing; using available cephadm binary for bootstrap)"


CEPHADM_BIN=''
if [ -x "$(pwd)/cephadm" ]; then
    CEPHADM_BIN="$(pwd)/cephadm"
fi
if [ -z "$CEPHADM_BIN" ]; then
    CEPHADM_BIN="$(command -v cephadm 2>/dev/null || true)"
fi
if [ -z "$CEPHADM_BIN" ]; then
    # /usr/sbin is not always in PATH for non-root SSH sessions on Debian
    for candidate in /usr/sbin/cephadm /usr/bin/cephadm /sbin/cephadm; do
        if [ -x "$candidate" ]; then
            CEPHADM_BIN="$candidate"
            break
        fi
    done
fi
if [ -z "$CEPHADM_BIN" ]; then
    log_error "cephadm was not found after installation (searched offline storage, PATH, and /usr/sbin, /usr/bin, /sbin)"
    exit 1
fi
log_info "Using cephadm binary: $CEPHADM_BIN"

if [ -z "$CEPH_IMAGE_INPUT" ]; then
    log_error "Missing required Ceph image argument (storage addon additionalImages entry)"
    exit 1
fi


# Determine the monitor IP address for the bootstrap process (first non-loopback IP)
MON_IP="$(hostname -I | awk '{print $1}')"
if [ -z "$MON_IP" ]; then
    log_error "Failed to resolve monitor IP from hostname -I"
    exit 1
fi

log_info "Bootstrapping Ceph cluster with image '$CEPH_IMAGE' and MON_IP '$MON_IP'"
log_info "Using cephadm SSH user '$CEPH_SSH_USER' for host management"
if [ -n "$OSD_CRUSH_CHOOSELEAF_TYPE" ]; then
    log_info "Requested osd_crush_chooseleaf_type=$OSD_CRUSH_CHOOSELEAF_TYPE"
fi
if [ -n "$MON_COUNT" ] || [ -n "$MGR_COUNT" ] || [ -n "$MDS_COUNT" ]; then
    log_info "Requested daemon placement counts: mon='${MON_COUNT:-<ceph-default>}', mgr='${MGR_COUNT:-<ceph-default>}', mds='${MDS_COUNT:-<ceph-default>}'"
fi

# Fresh-install behavior: if cluster state already exists on this node (including leftovers from
# an interrupted previous run), remove it automatically so we always bootstrap a clean, new cluster.
EXISTING_FSIDS="$(sudo ls /var/lib/ceph 2>/dev/null | grep -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || true)"

if [ -n "$EXISTING_FSIDS" ]; then
    log_info "WARNING: Existing Ceph cluster state detected on this node."
    log_info "WARNING: Existing Ceph cluster(s) will be removed automatically before new bootstrap."
    log_info "WARNING: ALL DATA in those cluster(s) will be lost."

    while IFS= read -r existing_fsid; do
        [ -n "$existing_fsid" ] || continue
        log_info "Removing existing Ceph cluster fsid '$existing_fsid'"

        if ! timeout 300 sudo "$CEPHADM_BIN" rm-cluster --force --zap-osds --fsid "$existing_fsid"; then
            log_info "rm-cluster failed for '$existing_fsid' (continuing with manual cleanup of Ceph directories/services)"
        fi
    done <<< "$EXISTING_FSIDS"

    # Ensure no stale Ceph runtime/config state survives the auto-cleanup.
    sudo systemctl stop 'ceph-*.target' 2>/dev/null || true
    sudo systemctl stop 'ceph-*.service' 2>/dev/null || true
    sudo systemctl stop ceph.target 2>/dev/null || true
    sudo rm -rf /etc/ceph /var/lib/ceph /var/log/ceph /run/ceph

    log_info "Finished cleanup of existing Ceph cluster state"
fi


if ! sudo "$CEPHADM_BIN" --image "$CEPH_IMAGE" bootstrap --mon-ip "$MON_IP" --ssh-user "$CEPH_SSH_USER" --skip-pull --allow-mismatched-release --skip-monitoring-stack; then
    log_error "cephadm bootstrap failed"
    exit 1
fi
log_info "Ceph cluster bootstrap completed on Debian"


log_info "A new (empty) volume drive will be consumed to create the Ceph OSD."
log_info "Attach a raw/unused disk to an OSD host, then let cephadm provision the OSD on it."
CEPH_PUB_KEY="$(sudo cat /etc/ceph/ceph.pub 2>/dev/null)"
if [ -n "$CEPH_PUB_KEY" ]; then
    log_info "cephadm cluster public key (authorize on additional OSD hosts via prepare-ceph-osd-host.sh):"
    echo "$CEPH_PUB_KEY" | sed 's/^/[CephNew]   /'
    echo "K2S_CEPH_PUB_KEY=${CEPH_PUB_KEY}"
fi


log_info "Creating CephFS filesystem '$CEPH_FS_NAME' and collecting connection details"

for attempt in $(seq 1 18); do
    if timeout 30 sudo "$CEPHADM_BIN" shell -- ceph -s >/dev/null 2>&1; then
        break
    fi

    if [ "$attempt" -eq 18 ]; then
        log_error "Ceph did not become ready for shell commands after bootstrap."
        exit 1
    fi

    log_info "Ceph command interface not ready yet (attempt $attempt/18). Retrying in 10s..."
    sleep 10
done

# Offline/air-gapped: stop the cephadm mgr module from resolving the container image to a
# registry digest (its default, use_repo_digest=true). Digest resolution requires reaching the
# image registry (e.g. quay.io); when it is unreachable, orchestrator-deployed daemons such as
# the MDS never start (MDS_ALL_DOWN / MDS_UP_LESS_THAN_MAX) because podman tries to pull a
# digest-pinned reference that is not loaded locally. Pinning to the tag of the image already
# loaded during offline import lets MDS/OSD/MGR (re)deploy without any network access.
if ! sudo "$CEPHADM_BIN" shell -- ceph config set mgr mgr/cephadm/use_repo_digest false; then
    log_info "Failed to set mgr/cephadm/use_repo_digest=false (continuing; MDS deploy may require network)"
fi
if ! sudo "$CEPHADM_BIN" shell -- ceph config set global container_image "$CEPH_IMAGE"; then
    log_info "Failed to pin global container_image to '$CEPH_IMAGE' (continuing)"
fi

if [ -n "$OSD_CRUSH_CHOOSELEAF_TYPE" ]; then
    if ! sudo "$CEPHADM_BIN" shell -- ceph config set osd osd_crush_chooseleaf_type "$OSD_CRUSH_CHOOSELEAF_TYPE"; then
        log_error "Failed to set osd_crush_chooseleaf_type to '$OSD_CRUSH_CHOOSELEAF_TYPE'"
        exit 1
    fi
    log_info "Configured osd_crush_chooseleaf_type=$OSD_CRUSH_CHOOSELEAF_TYPE"
fi

if [ -n "$MON_COUNT" ]; then
    if ! sudo "$CEPHADM_BIN" shell -- ceph orch apply mon --placement="count:${MON_COUNT}"; then
        log_error "Failed to apply mon placement count '$MON_COUNT'"
        exit 1
    fi
    log_info "Configured mon placement count=$MON_COUNT"
fi

if [ -n "$MGR_COUNT" ]; then
    if ! sudo "$CEPHADM_BIN" shell -- ceph orch apply mgr --placement="count:${MGR_COUNT}"; then
        log_error "Failed to apply mgr placement count '$MGR_COUNT'"
        exit 1
    fi
    log_info "Configured mgr placement count=$MGR_COUNT"
fi

if ! CLUSTER_DETAILS="$(timeout 900 sudo "$CEPHADM_BIN" shell --env K2S_FS_NAME="$CEPH_FS_NAME" --env K2S_MDS_COUNT="$MDS_COUNT" -- bash -c '
    # Create the CephFS volume (idempotent). This also deploys an MDS and
    # creates the "cephfs.<name>.meta" / "cephfs.<name>.data" pools.
    ceph fs volume create "$K2S_FS_NAME" >/dev/null 2>&1 || true

    if [ -n "$K2S_MDS_COUNT" ]; then
        ceph orch apply mds "$K2S_FS_NAME" --placement="count:${K2S_MDS_COUNT}" >/dev/null
    fi

    FSID="$(ceph fsid 2>/dev/null)"
    ADMIN_KEY="$(ceph auth get-key client.admin 2>/dev/null)"

    # Monitor endpoints: extract the v1 (msgr1) "IP:6789" addresses used by the CSI driver.
    MON_ENDPOINTS="$(ceph mon dump 2>/dev/null | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}:6789" | sort -u | paste -sd, -)"

    # Data pool for the filesystem. Prefer querying it; fall back to the
    # deterministic name that "ceph fs volume create" uses.
    DATA_POOL="$(ceph fs ls 2>/dev/null | sed -n "s/.*name: ${K2S_FS_NAME},.*data pools: \[\([^ ]*\).*/\1/p")"
    if [ -z "$DATA_POOL" ]; then
        DATA_POOL="cephfs.${K2S_FS_NAME}.data"
    fi

    echo "K2S_CEPH_FSID=${FSID}"
    echo "K2S_CEPH_MON_ENDPOINTS=${MON_ENDPOINTS}"
    echo "K2S_CEPH_ADMIN_KEY=${ADMIN_KEY}"
    echo "K2S_CEPH_FS_NAME=${K2S_FS_NAME}"
    echo "K2S_CEPH_DATA_POOL=${DATA_POOL}"
    # ceph-csi expects the user id WITHOUT the "client." prefix (it prepends it internally).
    echo "K2S_CEPH_USER=admin"
')"; then
    log_error "Timed out while creating CephFS/collecting cluster details via cephadm shell."
    log_error "If this follows a previous failed run, clean up the stale cluster first and retry enable."
    exit 1
fi

echo "$CLUSTER_DETAILS" | grep -E '^K2S_CEPH_' | while IFS= read -r line; do
    case "$line" in
        K2S_CEPH_ADMIN_KEY=*) log_info "Collected K2S_CEPH_ADMIN_KEY=<hidden>" ;;
        *) log_info "Collected $line" ;;
    esac
done
echo "$CLUSTER_DETAILS" | grep -E '^K2S_CEPH_'

COLLECTED_FSID="$(echo "$CLUSTER_DETAILS" | sed -n 's/^K2S_CEPH_FSID=//p')"
COLLECTED_KEY="$(echo "$CLUSTER_DETAILS" | sed -n 's/^K2S_CEPH_ADMIN_KEY=//p')"
COLLECTED_MONS="$(echo "$CLUSTER_DETAILS" | sed -n 's/^K2S_CEPH_MON_ENDPOINTS=//p')"
if [ -z "$COLLECTED_FSID" ] || [ -z "$COLLECTED_KEY" ] || [ -z "$COLLECTED_MONS" ]; then
    log_error "Failed to read back the Ceph connection details from the cluster (fsid/key/mon endpoints missing)."
    log_error "The Ceph cluster may not be healthy yet. Check 'sudo cephadm shell -- ceph -s' on the node."
    exit 1
fi

# If OSD-level CRUSH placement was requested, create a named rule and explicitly apply it to
# the CephFS pools. 'ceph config set osd osd_crush_chooseleaf_type' only affects future
# auto-generated rules; pools created by 'ceph fs volume create' inherit the existing
# 'replicated_rule' (chooseleaf type host) and must be updated explicitly.
if [ "${OSD_CRUSH_CHOOSELEAF_TYPE:-}" = "0" ]; then
    log_info "Creating OSD-level CRUSH rule 'k2s-osd-rule' for single-host placement..."
    if ! sudo "$CEPHADM_BIN" shell -- ceph osd crush rule create-replicated k2s-osd-rule default osd; then
        log_error "Failed to create OSD-level CRUSH rule 'k2s-osd-rule'"
        exit 1
    fi
    if ! sudo "$CEPHADM_BIN" shell -- ceph osd pool set "cephfs.${CEPH_FS_NAME}.meta" crush_rule k2s-osd-rule; then
        log_error "Failed to apply k2s-osd-rule to pool 'cephfs.${CEPH_FS_NAME}.meta'"
        exit 1
    fi
    if ! sudo "$CEPHADM_BIN" shell -- ceph osd pool set "cephfs.${CEPH_FS_NAME}.data" crush_rule k2s-osd-rule; then
        log_error "Failed to apply k2s-osd-rule to pool 'cephfs.${CEPH_FS_NAME}.data'"
        exit 1
    fi
fi

log_info "Finished collecting Ceph cluster connection details"
