#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

# Apply Debian delta package updates
# This script is copied into the delta package and executed on the Kubemaster VM
# to apply package changes (add/remove/upgrade) and run kubeadm upgrade.

set -euo pipefail

echo "[debian-delta] Apply start"

if [[ $EUID -ne 0 ]]; then
    echo "Run as root" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ADDED_FILE=packages.added
REMOVED_FILE=packages.removed
UPGRADED_FILE=packages.upgraded
PKG_DIR=packages
INSTALL_SPECS=()

# Remove packages that were removed between versions
if [[ -f "$REMOVED_FILE" ]]; then
    echo "[debian-delta] Purging removed packages"
    xargs -r dpkg --purge < "$REMOVED_FILE" || true
fi

# Collect added packages
if [[ -f "$ADDED_FILE" ]]; then
    while IFS= read -r l; do
        [[ -z "$l" ]] && continue
        INSTALL_SPECS+=("$l")
    done < "$ADDED_FILE"
fi

# Collect upgraded packages (format: name old_version new_version)
if [[ -f "$UPGRADED_FILE" ]]; then
    while IFS= read -r l; do
        [[ -z "$l" ]] && continue
        PKG=$(echo "$l" | awk '{print $1}')
        NEWV=$(echo "$l" | awk '{print $3}')
        INSTALL_SPECS+=("${PKG}=${NEWV}")
    done < "$UPGRADED_FILE"
fi

# Install local .deb files if present
if [[ -d "$PKG_DIR" ]]; then
    shopt -s nullglob
    DEBS=($PKG_DIR/*.deb)
    if [[ ${#DEBS[@]} -gt 0 ]]; then
        echo "[debian-delta] Installing local .deb files (${#DEBS[@]})"
        dpkg -i "${DEBS[@]}" || true
        # Attempt to fix missing dependencies without network if possible
        if command -v apt-get >/dev/null 2>&1; then
            apt-get -y --no-install-recommends install -f || true
        fi
    else
        echo "[debian-delta] No local .deb files present"
    fi
fi

# Verify installed versions match expectations
if [[ ${#INSTALL_SPECS[@]} -gt 0 ]]; then
    echo "[debian-delta] Ensuring target versions for ${#INSTALL_SPECS[@]} packages"
    # Attempt version enforcement using dpkg (requires local .debs); fallback echo warnings
    for spec in "${INSTALL_SPECS[@]}"; do
        P=${spec%%=*}
        V=${spec#*=}
        CUR=$(dpkg-query -W -f='${Version}' "$P" 2>/dev/null || echo missing)
        if [[ "$CUR" != "$V" ]]; then
            echo "[debian-delta][warn] Version mismatch for $P expected $V got $CUR"
        fi
    done
else
    echo "[debian-delta] No packages specified for install/upgrade"
fi

# Run kubeadm upgrade to migrate cluster configuration (manifests, kubelet flags, etc.)
echo "[debian-delta] Running kubeadm upgrade to migrate cluster configuration"
KUBE_VERSION=$(kubelet --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "")

if [[ -n "$KUBE_VERSION" ]]; then
    echo "[debian-delta] Detected Kubernetes version: v${KUBE_VERSION}"
    
    # Reload systemd to pick up any changes to kubelet.service
    systemctl daemon-reload
    
    # Run kubeadm upgrade apply with appropriate flags
    # --yes: auto-approve the upgrade
    # --certificate-renewal=false: preserve existing certificates
    # --etcd-upgrade=false: do not upgrade etcd (already handled by package)
    if kubeadm upgrade apply "v${KUBE_VERSION}" --yes --certificate-renewal=false --etcd-upgrade=false 2>&1; then
        echo "[debian-delta] kubeadm upgrade completed successfully"
    else
        echo "[debian-delta][warn] kubeadm upgrade encountered issues, attempting fallback cleanup"
        
        # Fallback: Clean deprecated kubelet flags manually
        KUBEADM_FLAGS_FILE="/var/lib/kubelet/kubeadm-flags.env"
        if [[ -f "$KUBEADM_FLAGS_FILE" ]]; then
            echo "[debian-delta] Cleaning deprecated kubelet flags from $KUBEADM_FLAGS_FILE"
            # Remove --pod-infra-container-image (deprecated in 1.27, removed in 1.34)
            sed -i 's/--pod-infra-container-image=[^ "]*//g' "$KUBEADM_FLAGS_FILE"
            # Clean up whitespace
            sed -i 's/  */ /g' "$KUBEADM_FLAGS_FILE"
            sed -i 's/" /"/g' "$KUBEADM_FLAGS_FILE"
            echo "[debian-delta] Kubelet flags after cleanup: $(cat $KUBEADM_FLAGS_FILE)"
        fi
    fi
else
    echo "[debian-delta][warn] Could not detect Kubernetes version, skipping kubeadm upgrade"
fi

echo "[debian-delta] Apply complete"
