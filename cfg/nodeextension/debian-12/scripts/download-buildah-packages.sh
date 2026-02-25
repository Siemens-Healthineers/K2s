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

set -euo pipefail

BUILDAH_DEB_PACKAGES_PATH="${1:?Argument missing: BuildahDebPackagesPath}"

echo "[BuildahPkg] Starting download of buildah packages"
echo "[BuildahPkg] Target path: $BUILDAH_DEB_PACKAGES_PATH"

# ---------------------------------------------------------------------------
# Prepare target directory
# ---------------------------------------------------------------------------
if [ -d "$BUILDAH_DEB_PACKAGES_PATH" ]; then
    rm -rf "$BUILDAH_DEB_PACKAGES_PATH"
fi
mkdir -p "$BUILDAH_DEB_PACKAGES_PATH"

# ---------------------------------------------------------------------------
# Download buildah and its dependencies
# ---------------------------------------------------------------------------
echo "[BuildahPkg] Downloading buildah package"
cd "$BUILDAH_DEB_PACKAGES_PATH"

# Download the main buildah package
sudo apt-get download buildah

# Simulate install to resolve all required dependencies, then download them
echo "[BuildahPkg] Resolving and downloading buildah dependencies"
sudo DEBIAN_FRONTEND=noninteractive apt-get --reinstall install -y \
    -o DPkg::Options::="--force-confnew" \
    --no-install-recommends \
    --no-install-suggests \
    --simulate \
    ./buildah*.deb \
    | grep 'Inst ' \
    | cut -d ' ' -f 2 \
    | sort -u \
    | xargs sudo apt-get download

# Explicitly download the recommended package crun
echo "[BuildahPkg] Downloading crun package"
sudo apt-get download crun

echo "[BuildahPkg] Downloaded packages:"
ls -1 "$BUILDAH_DEB_PACKAGES_PATH"

echo "[BuildahPkg] Finished downloading buildah packages successfully"
