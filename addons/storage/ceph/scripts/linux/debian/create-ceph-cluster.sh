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

# Ensure a container engine (podman) is available. cephadm requires podman (or docker)
# to pull and run the Ceph daemon containers; on a freshly provisioned node it may be missing.
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

# Pull the Ceph image FIRST so the exact release/version can be read from it. The image tag may be a
# rolling tag (e.g. 'v20') that does NOT map to a 'download.ceph.com/rpm-<version>' path, so the
# authoritative version must come from the image itself, not from the tag. Deriving it from the tag
# turned 'v20' into an invalid 'rpm-20' URL whose 404 HTML page was saved as 'cephadm' and then
# failed to run ("Syntax error: redirection unexpected").
if [ -n "$PROXY" ]; then
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

# Read the authoritative Ceph version string from the pulled image, e.g.
#   "ceph version 20.2.2 (<hash>) tentacle (stable)"
# and derive BOTH the numeric version (20.2.2) used for the download.ceph.com 'rpm-<version>' path
# and the release codename (tentacle) used by 'cephadm add-repo --release'. Reading these from the
# image (not the tag) keeps bootstrap working with rolling tags such as 'v20'.
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

# Download the matching cephadm bootstrap binary. Validate that the download is the cephadm Python
# script and not an HTTP error page (a 404 saved as 'cephadm' fails with "redirection unexpected").
# Try the numeric version path first, then fall back to the release-codename path.
download_cephadm() {
    local url="$1"
    rm -f cephadm
    curl -x "$PROXY" --fail --silent --show-error --remote-name --location "$url" || return 1
    if ! head -n1 cephadm 2>/dev/null | grep -qE '^#!.*python'; then
        log_error "Downloaded file from '$url' is not the cephadm script (likely an HTTP error page)."
        rm -f cephadm
        return 1
    fi
    return 0
}

if download_cephadm "https://download.ceph.com/rpm-$CEPH_VERSION/el9/noarch/cephadm"; then
    log_info "Downloaded cephadm bootstrap binary for version '$CEPH_VERSION'"
elif download_cephadm "https://download.ceph.com/rpm-$CEPH_RELEASE/el9/noarch/cephadm"; then
    log_info "Downloaded cephadm bootstrap binary for release '$CEPH_RELEASE'"
else
    log_error "Failed to download a valid cephadm bootstrap binary from download.ceph.com (tried version '$CEPH_VERSION' and release '$CEPH_RELEASE')."
    exit 1
fi

# Make the downloaded cephadm binary executable
sudo chmod +x cephadm

# Install gnupg for apt-key management (required for adding the Ceph repository)
sudo apt-get install -y gnupg
sudo rm -f /etc/apt/trusted.gpg.d/ceph.asc

# cephadm's add-repo/install use Python (urllib), which does NOT read the apt proxy config.
# Pass the proxy via the standard http_proxy/https_proxy env vars so it can reach
# download.ceph.com; on air-gapped nodes DNS resolution otherwise fails.
CEPHADM_PROXY_ENV=()
if [ -n "$PROXY" ]; then
    CEPHADM_PROXY_ENV=(http_proxy="$PROXY" https_proxy="$PROXY" HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY")
fi

# Add the Ceph repository for the detected release and install cephadm.
# These are best-effort: they provide the host-side 'ceph' CLI but are not required
# for the bootstrap itself (which runs everything inside the pre-pulled container image).
sudo env "${CEPHADM_PROXY_ENV[@]}" ./cephadm add-repo --release "$CEPH_RELEASE" || \
    log_info "add-repo failed (continuing; host-side ceph CLI may be unavailable)"

sudo env "${CEPHADM_PROXY_ENV[@]}" ./cephadm install || \
    log_info "cephadm install failed (continuing; using downloaded cephadm binary for bootstrap)"

# Prefer the freshly downloaded cephadm binary: its version matches the target Ceph image,
# whereas a system-installed cephadm may be an older/mismatched release.
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
    log_error "cephadm was not found after installation (searched PATH and /usr/sbin, /usr/bin, /sbin)"
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

# --skip-pull: image is already present in podman's store (pulled above).
# --allow-mismatched-release: the container image is the authoritative Ceph version;
#   tolerate a version-string difference between the cephadm tool and the image release.
# --skip-monitoring-stack: do NOT deploy the Prometheus/Grafana/Alertmanager/node-exporter
#   monitoring stack. K2s only needs core Ceph + CephFS for CSI, so skipping it avoids pulling
#   quay.io/ceph/grafana and quay.io/prometheus/* images and keeps the footprint minimal.
if ! sudo "$CEPHADM_BIN" --image "$CEPH_IMAGE" bootstrap --mon-ip "$MON_IP" --ssh-user "$CEPH_SSH_USER" --skip-pull --allow-mismatched-release --skip-monitoring-stack; then
    log_error "cephadm bootstrap failed"
    exit 1
fi
log_info "Ceph cluster bootstrap completed on Debian"

# After bootstrap, surface OSD guidance: cephadm consumes an empty/raw data drive on a host to
# create an OSD. Emit the cephadm cluster public key so ADDITIONAL OSD hosts can authorize it for
# '$CEPH_SSH_USER' SSH access (see prepare-ceph-osd-host.sh); on the bootstrap node cephadm already
# has key access.
log_info "A new (empty) volume drive will be consumed to create the Ceph OSD."
log_info "Attach a raw/unused disk to an OSD host, then let cephadm provision the OSD on it."
CEPH_PUB_KEY="$(sudo cat /etc/ceph/ceph.pub 2>/dev/null)"
if [ -n "$CEPH_PUB_KEY" ]; then
    log_info "cephadm cluster public key (authorize on additional OSD hosts via prepare-ceph-osd-host.sh):"
    echo "$CEPH_PUB_KEY" | sed 's/^/[CephNew]   /'
    echo "K2S_CEPH_PUB_KEY=${CEPH_PUB_KEY}"
fi

# ---------------------------------------------------------------------------
# Create the CephFS filesystem and read back the ACTUAL cluster connection
# values so the addon can persist them into ceph-config.json and connect the
# CSI driver to the freshly provisioned cluster (instead of the placeholder
# values shipped in the config template).
#
# All ceph commands run inside 'cephadm shell' so they work even when a
# host-side ceph CLI was not installed. The resulting values are emitted as
# K2S_CEPH_* marker lines that New-CephCluster.ps1 parses.
# ---------------------------------------------------------------------------
log_info "Creating CephFS filesystem '$CEPH_FS_NAME' and collecting connection details"

# Wait until cephadm shell can execute Ceph commands reliably. Right after bootstrap,
# manager/orchestrator restarts can still be settling and a single shell invocation may
# block long enough to hit the detail-collection timeout.
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

# Re-emit the marker lines on stdout so the calling PowerShell can parse them.
# (Do NOT log the admin key to the console; the PowerShell side masks it.)
echo "$CLUSTER_DETAILS" | grep -E '^K2S_CEPH_' | while IFS= read -r line; do
    case "$line" in
        K2S_CEPH_ADMIN_KEY=*) log_info "Collected K2S_CEPH_ADMIN_KEY=<hidden>" ;;
        *) log_info "Collected $line" ;;
    esac
done
echo "$CLUSTER_DETAILS" | grep -E '^K2S_CEPH_'

# Fail loudly if the essential connection values could not be read back. Otherwise the addon
# would continue with the placeholder config values and the CSI driver would never connect.
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
    # The built-in .mgr pool is created by cephadm during bootstrap with crush_rule 0
    # (replicated_rule, host-level). On a single-host cluster only 1 OSD can be placed,
    # causing a permanent PG_DEGRADED / PG_AVAILABILITY warning. Apply the same OSD-level
    # rule so all 3 OSDs can serve the single .mgr PG.
    if ! sudo "$CEPHADM_BIN" shell -- ceph osd pool set .mgr crush_rule k2s-osd-rule; then
        log_error "Failed to apply k2s-osd-rule to pool '.mgr'"
        exit 1
    fi
    log_info "Applied OSD-level CRUSH rule to CephFS pools (meta + data) and .mgr pool"
fi

log_info "Finished collecting Ceph cluster connection details"
