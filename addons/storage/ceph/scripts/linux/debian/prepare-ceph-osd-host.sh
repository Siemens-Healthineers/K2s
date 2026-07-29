#!/bin/bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT
#
# prepare-ceph-osd-host.sh  -  Debian (12/13) variant
#
# Prepares THIS machine to join an existing cephadm-managed Ceph cluster as an OSD host.
# cephadm manages cluster hosts over SSH as the 'root' user using the cluster's own key pair
# (/etc/ceph/ceph.pub on the bootstrap/MGR node). For cephadm to add this host and deploy OSD
# daemons on its data drives, that cluster public key must be authorized for root login here and
# root key-based SSH must be enabled.
#
# This script automates the manual host-preparation steps:
#   Install a container runtime (docker-ce / containerd.io) and lvm2 - both required by cephadm
#   to deploy an OSD daemon and carve the OSD out of a raw drive:
#     - sudo apt install -y ca-certificates curl gnupg lsb-release
#     - add the Docker apt repository + GPG key
#     - sudo apt install -y docker-ce docker-ce-cli containerd.io
#     - sudo apt install -y lvm2
#   Authorize the cephadm cluster key for root SSH:
#     1. sudo cat /etc/ceph/ceph.pub        (run on the MGR node to obtain the key -> pass as arg)
#     2. sudo mkdir -p /root/.ssh
#     3. sudo chmod 700 /root/.ssh
#     4. append the key to /root/.ssh/authorized_keys
#     5. sudo chmod 600 /root/.ssh/authorized_keys
#     6. enable PermitRootLogin (prohibit-password) + PubkeyAuthentication in sshd
#     7. sudo systemctl restart ssh
#
# Invoked remotely (Invoke-RemoteScript) or run directly on the OSD host.
#
# Arguments (order-independent):
#   The cephadm cluster public key (contents of /etc/ceph/ceph.pub on the MGR node). An OpenSSH
#     public key contains spaces (type + base64 blob + optional comment); it may be passed either
#     quoted as one argument or as several space-separated arguments - they are reassembled.
#   Optional HTTP/HTTPS proxy URL (e.g. the K2s transparent proxy http://<kubeswitch-ip>:8181).
#     The proxy is recognised by its 'http://' or 'https://' prefix, so it can appear before or
#     after the key without being confused with a key fragment.
#
# Examples:
#   ./prepare-ceph-osd-host.sh ssh-ed25519 AAAA... ceph-<fsid> http://172.19.1.1:8181
#   ./prepare-ceph-osd-host.sh "ssh-ed25519 AAAA... ceph-<fsid>" http://172.19.1.1:8181

set -uo pipefail

# Separate the (possibly space-containing) public key from the optional proxy URL. Everything that
# is not an http(s):// URL is treated as part of the key, so quoting the key is optional and the
# proxy may be placed before or after it.
CEPH_PUB_KEY=""
PROXY=""
for arg in "$@"; do
    case "$arg" in
        http://*|https://*)
            PROXY="$arg"
            ;;
        *)
            if [ -z "$CEPH_PUB_KEY" ]; then
                CEPH_PUB_KEY="$arg"
            else
                CEPH_PUB_KEY="$CEPH_PUB_KEY $arg"
            fi
            ;;
    esac
done

log_info() {
    echo "[CephOsd] $1"
}

log_error() {
    echo "[CephOsd] ERROR: $1" >&2
}

log_info "Preparing this machine as a Ceph OSD host on Debian"

if [ -z "$CEPH_PUB_KEY" ]; then
    log_error "Missing required cephadm public key argument (contents of /etc/ceph/ceph.pub from the MGR node)."
    exit 1
fi

# Basic sanity check: cephadm keys are OpenSSH public keys (ssh-rsa / ssh-ed25519 / ecdsa-...).
case "$CEPH_PUB_KEY" in
    ssh-*|ecdsa-*) : ;;
    *)
        log_error "The provided key does not look like an OpenSSH public key (expected it to start with 'ssh-' or 'ecdsa-')."
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# Install container runtime (docker-ce / containerd.io) and lvm2 required by
# cephadm to deploy the OSD daemon and provision the OSD on a raw drive.
# ---------------------------------------------------------------------------

# Configure apt to use the K2s proxy when provided (air-gapped nodes reach the internet only
# through it). Removed again on exit so it does not linger in the node's apt configuration.
cleanup_proxy_config() {
    if [ -n "$PROXY" ]; then
        sudo rm -f /etc/apt/apt.conf.d/95k2s-proxy
    fi
}
trap cleanup_proxy_config EXIT

if [ -n "$PROXY" ]; then
    log_info "Configuring apt proxy: $PROXY"
    printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "$PROXY" "$PROXY" | sudo tee /etc/apt/apt.conf.d/95k2s-proxy > /dev/null
fi

# Wait for any other apt/dpkg run to release the lock instead of failing (the manual workaround
# for the lock error was to restart the VM; here we simply wait for it to clear).
wait_for_apt_lock() {
    local waited=0
    while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
        if [ "$waited" -ge 300 ]; then
            log_error "Timed out waiting for the apt/dpkg lock to be released (another package operation is running)."
            return 1
        fi
        log_info "apt/dpkg is locked by another process; waiting..."
        sleep 5
        waited=$((waited + 5))
    done
    return 0
}

# curl fetches the Docker GPG key; route it through the proxy when set.
CURL_PROXY_ARGS=()
if [ -n "$PROXY" ]; then
    CURL_PROXY_ARGS=(-x "$PROXY")
else
    log_info "No proxy argument was provided; the Docker GPG key / packages are fetched directly."
    log_info "On an air-gapped node this will fail to resolve download.docker.com - re-run passing the K2s proxy URL, e.g. http://<kubeswitch-ip>:8181"
fi

wait_for_apt_lock || exit 1
if ! sudo apt-get update; then
    log_error "'apt-get update' failed. If it reported a lock error, ensure no other apt process is running."
    exit 1
fi

# Install prerequisite packages, skipping any that are already present (e.g. installed via dpkg
# during offline artifact import). Only the missing ones are handed to apt-get.
PREREQ_PKGS="ca-certificates curl gnupg lsb-release"
MISSING_PREREQ=""
for pkg in $PREREQ_PKGS; do
    dpkg -s "$pkg" >/dev/null 2>&1 || MISSING_PREREQ="$MISSING_PREREQ $pkg"
done
if [ -n "$MISSING_PREREQ" ]; then
    wait_for_apt_lock || exit 1
    # shellcheck disable=SC2086
    if ! sudo apt-get install -y $MISSING_PREREQ; then
        log_error "Failed to install prerequisite packages ($MISSING_PREREQ)."
        exit 1
    fi
else
    log_info "Prerequisite packages (ca-certificates, curl, gnupg, lsb-release) already installed; skipping"
fi

# Add the Docker apt repository + GPG key (idempotent). Skip the whole repository setup and
# install when Docker is already present (e.g. installed via dpkg during offline artifact import).
# containerd.io is NOT installed explicitly here: every K2s node already ships containerd, so it
# is expected to be present already (apt still pulls it as a docker-ce dependency if it is not).
if command -v docker >/dev/null 2>&1; then
    log_info "Docker (docker-ce) already installed; skipping Docker repository setup and install"
else
    sudo install -m 0755 -d /usr/share/keyrings
    if ! curl -fsSL "${CURL_PROXY_ARGS[@]}" https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor --yes -o /usr/share/keyrings/docker-archive-keyring.gpg; then
        log_error "Failed to download and import the Docker GPG key from download.docker.com."
        if [ -z "$PROXY" ]; then
            log_error "This node could not reach download.docker.com directly. Re-run this script passing the K2s proxy URL as an argument, e.g.:"
            log_error "  ./prepare-ceph-osd-host.sh <ceph-pub-key> http://<kubeswitch-ip>:8181"
        fi
        exit 1
    fi
    sudo chmod a+r /usr/share/keyrings/docker-archive-keyring.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    log_info "Configured Docker apt repository:"
    sudo cat /etc/apt/sources.list.d/docker.list | sed 's/^/[CephOsd]   /'

    wait_for_apt_lock || exit 1
    if ! sudo apt-get update; then
        log_error "'apt-get update' failed after adding the Docker repository."
        exit 1
    fi

    wait_for_apt_lock || exit 1
    if ! sudo apt-get install -y docker-ce docker-ce-cli; then
        log_error "Failed to install docker-ce / docker-ce-cli (required by cephadm)."
        exit 1
    fi
fi
log_info "Installed container runtime: $(command -v docker) / $(command -v containerd)"

# lvm2 provides the LVM tooling cephadm uses to create the OSD's logical volume on the drive.
# Skip when already present (e.g. installed via dpkg during offline artifact import).
if dpkg -s lvm2 >/dev/null 2>&1; then
    log_info "lvm2 already installed; skipping"
else
    wait_for_apt_lock || exit 1
    if ! sudo apt-get install -y lvm2; then
        log_error "Failed to install lvm2 (required by cephadm to create the OSD on a raw drive)."
        exit 1
    fi
    log_info "Installed lvm2"
fi

# 1) Ensure root's .ssh directory exists with correct permissions.
sudo mkdir -p /root/.ssh
sudo chmod 700 /root/.ssh

# 2) Authorize the cephadm public key for root (idempotent - avoid duplicate lines).
AUTH_KEYS="/root/.ssh/authorized_keys"
sudo touch "$AUTH_KEYS"
if sudo grep -qF "$CEPH_PUB_KEY" "$AUTH_KEYS"; then
    log_info "cephadm public key already present in $AUTH_KEYS"
else
    echo "$CEPH_PUB_KEY" | sudo tee -a "$AUTH_KEYS" > /dev/null
    log_info "Added cephadm public key to $AUTH_KEYS"
fi
sudo chmod 600 "$AUTH_KEYS"

# 3) Enable root key-based SSH login for cephadm. Use a dedicated drop-in so the main
#    sshd_config is left untouched (and to override any conflicting default).
SSHD_DROPIN="/etc/ssh/sshd_config.d/60-ceph-osd.conf"
sudo mkdir -p /etc/ssh/sshd_config.d
sudo tee "$SSHD_DROPIN" > /dev/null <<'EOF'
# Managed by K2s storage/ceph addon (prepare-ceph-osd-host.sh).
# Allows the cephadm cluster to manage this OSD host as root over SSH using its key pair.
PermitRootLogin prohibit-password
PubkeyAuthentication yes
EOF
log_info "Wrote sshd drop-in '$SSHD_DROPIN' (PermitRootLogin prohibit-password, PubkeyAuthentication yes)"

# 4) Show the effective settings for visibility.
log_info "Effective SSH root-login / pubkey settings:"
sudo grep -E '^(PermitRootLogin|PubkeyAuthentication)' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | sed 's/^/[CephOsd]   /' || true

# 5) Restart the SSH service so the new settings take effect. The unit is 'ssh' on Debian,
#    'sshd' on some distributions - try both.
if sudo systemctl restart ssh 2>/dev/null; then
    log_info "Restarted 'ssh' service"
elif sudo systemctl restart sshd 2>/dev/null; then
    log_info "Restarted 'sshd' service"
else
    log_error "Failed to restart the SSH service; restart it manually so cephadm can connect as root."
    exit 1
fi

log_info "This machine is ready to be added to the Ceph cluster as an OSD host."
log_info "A new volume drive on this machine will be consumed to create the OSD."
echo "K2S_CEPH_OSD_HOST_READY=1"
exit 0
