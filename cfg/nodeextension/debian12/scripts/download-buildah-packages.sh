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

# Explicitly download the recommended package crun (with retry + repair)
log_info "Downloading recommended package: crun"
for attempt in 1 2; do
    if (cd "$BUILDAH_DEB_PACKAGES_PATH" && sudo apt-get download crun 2>/dev/null); then
        break
    fi

    log_info "crun download attempt $attempt failed; running repair"
    sudo dpkg --configure -a >/dev/null 2>&1 || true
    sudo apt --fix-broken install -y >/dev/null 2>&1 || true

    if [ "$attempt" -eq 2 ]; then
        log_info "WARNING: failed to download crun after 2 attempts"
    fi
done

# crun's dependencies (e.g. libyajl2) may be pre-installed on the control plane
# and therefore missed by the simulate-reinstall approach above.
# Discover them dynamically via a fresh repo simulation and download what is missing.
log_info "Downloading missing dependencies of crun"
cd "$BUILDAH_DEB_PACKAGES_PATH" && \
sudo DEBIAN_FRONTEND=noninteractive \
    apt-get --simulate install \
    --no-install-recommends --no-install-suggests \
    crun 2>/dev/null \
    | grep '^Inst ' \
    | cut -d ' ' -f 2 \
    | sort -u \
    | xargs -r sudo apt-get download 2>/dev/null || true

log_info "Downloaded packages:"
ls -1 "$BUILDAH_DEB_PACKAGES_PATH"

log_info "Finished downloading buildah packages successfully"
