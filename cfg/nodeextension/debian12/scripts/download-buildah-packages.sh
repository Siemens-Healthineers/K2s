#!/bin/bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT
#
# download-buildah-packages.sh
#
# Downloads buildah and its dependencies as .deb packages from the Debian APT
# repository for offline installation.
#
# Arguments:
#   $1 - Target path on the remote machine to store downloaded .deb packages
#        (e.g. /home/sk/apt-offline-k2s/buildah)

BUILDAH_DEB_PACKAGES_PATH="${1:?Argument missing: BuildahDebPackagesPath}"

log_info() {
    echo "[BuildahPkg] $1"
}

log_info "Starting download of buildah packages"
log_info "Target path: $BUILDAH_DEB_PACKAGES_PATH"

# ---------------------------------------------------------------------------
# Prepare target directory
# ---------------------------------------------------------------------------
if [ -d "$BUILDAH_DEB_PACKAGES_PATH" ]; then
    rm -rf "$BUILDAH_DEB_PACKAGES_PATH"
fi
mkdir -p "$BUILDAH_DEB_PACKAGES_PATH"

# APT sandbox config
echo 'APT::Sandbox::User "root";' | sudo tee /etc/apt/apt.conf.d/10sandbox-for-k2s > /dev/null

cd "$BUILDAH_DEB_PACKAGES_PATH"

download_packages() {
    local package_name="$1"
    local deb_pattern="${package_name%%=*}*.deb"

    log_info "Downloading: $package_name"

    cd "$BUILDAH_DEB_PACKAGES_PATH" && sudo apt-get download "$package_name" 2>/dev/null || true

    if ls "$BUILDAH_DEB_PACKAGES_PATH"/${deb_pattern} >/dev/null 2>&1; then
        cd "$BUILDAH_DEB_PACKAGES_PATH" && \
        sudo DEBIAN_FRONTEND=noninteractive \
            apt-get --reinstall install -y \
            -o DPkg::Options::="--force-confnew" \
            --no-install-recommends --no-install-suggests \
            --simulate ./${deb_pattern} 2>/dev/null \
            | grep 'Inst ' \
            | cut -d ' ' -f 2 \
            | sort -u \
            | xargs -r sudo apt-get download 2>/dev/null || true
    fi
}

log_info "=== Downloading buildah and dependencies ==="

download_packages 'buildah'

# NOTE: crun is only a Recommends (optional) dependency of buildah and its
# post-install script fails on some VM kernel configurations. We intentionally
# skip downloading it; buildah works correctly without it.

log_info "Downloaded packages:"
ls -1 "$BUILDAH_DEB_PACKAGES_PATH"

log_info "Finished downloading buildah packages successfully"
