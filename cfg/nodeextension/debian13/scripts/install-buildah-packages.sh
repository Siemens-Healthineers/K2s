#!/bin/bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

set -euo pipefail

BUILDAH_DEB_PACKAGES_PATH="${1:?Argument missing: BuildahDebPackagesPath}"

echo "[BuildahInstall] Installing buildah packages from '$BUILDAH_DEB_PACKAGES_PATH'"

# ---------------------------------------------------------------------------
# Wait for dpkg lock (unattended-upgrades may hold it)
# ---------------------------------------------------------------------------
wait_for_dpkg_lock() {
    local max_wait=300  # 5 minutes
    local waited=0
    while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
          sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
        if [ $waited -ge $max_wait ]; then
            echo "[BuildahInstall] ERROR: Timeout waiting for dpkg lock after ${max_wait}s" >&2
            exit 1
        fi
        echo "[BuildahInstall] Waiting for dpkg lock (held by another process)..."
        sleep 5
        waited=$((waited + 5))
    done
    if [ $waited -gt 0 ]; then
        echo "[BuildahInstall] dpkg lock released after ${waited}s"
    fi
}

wait_for_dpkg_lock

# Multi-pass dpkg: alphabetical glob order can place a package before its deps
# are configured. Three passes let each iteration configure more packages.
# --no-remove prevents apt --fix-broken from evicting buildah.
for pass in 1 2 3; do
    echo "[BuildahInstall] dpkg install pass $pass"
    sudo DEBIAN_FRONTEND=noninteractive dpkg --force-confnew -i "$BUILDAH_DEB_PACKAGES_PATH"/*.deb 2>&1 || true
done

sudo DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y --no-remove 2>&1 || true

# Verify buildah is actually usable - this is the definitive success check.
if ! sudo buildah --version > /dev/null 2>&1; then
    echo "[BuildahInstall] ERROR: buildah is not functional after installation"
    exit 1
fi

# netavark requires nft from nftables at runtime for networking during image builds.
if ! sudo dpkg-query -W -f='${Status}' nftables 2>/dev/null | grep -q "install ok installed"; then
    echo "[BuildahInstall] ERROR: nftables is not fully installed"
    exit 1
fi

if ! sudo nft --version > /dev/null 2>&1; then
    echo "[BuildahInstall] ERROR: nft binary is not available"
    exit 1
fi

echo "[BuildahInstall] Finished installing buildah"
