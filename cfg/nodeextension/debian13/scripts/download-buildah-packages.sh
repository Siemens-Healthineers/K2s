#!/bin/bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT
#
# download-buildah-packages.sh  -  Debian 13 (Trixie) variant
#
# Downloads buildah and its dependencies as .deb packages from the Debian APT
# repository for offline installation.
#
# Debian 13 differences vs Debian 12:
#   - buildah uses netavark + aardvark-dns as the network backend (not CNI plugins)
#   - netavark and aardvark-dns are recommended packages (skipped by
#     --no-install-recommends) so they are downloaded explicitly below
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

# Explicitly download Debian 13 networking stack packages for buildah.
# netavark is the default network backend for buildah 1.35+ (replaces CNI);
# aardvark-dns provides DNS resolution within buildah-managed networks.
# Both are recommended packages and therefore not captured by --no-install-recommends.
log_info "Downloading Debian 13 networking packages: netavark, aardvark-dns"
for pkg in netavark aardvark-dns; do
    for attempt in 1 2; do
        if (cd "$BUILDAH_DEB_PACKAGES_PATH" && sudo apt-get download "$pkg" 2>/dev/null); then
            break
        fi

        log_info "$pkg download attempt $attempt failed; running repair"
        sudo dpkg --configure -a >/dev/null 2>&1 || true
        sudo apt --fix-broken install -y >/dev/null 2>&1 || true

        if [ "$attempt" -eq 2 ]; then
            log_info "WARNING: failed to download $pkg after 2 attempts"
        fi
    done
done

log_info "Downloaded packages:"
ls -1 "$BUILDAH_DEB_PACKAGES_PATH"

log_info "Finished downloading buildah packages successfully"
