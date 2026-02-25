#!/bin/bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT
#
# install-buildah-packages.sh
#
# Installs buildah and its dependencies from pre-downloaded .deb packages.
#
# Arguments:
#   $1 - Buildah deb packages path on the remote machine (e.g. /home/sk/apt-offline-k2s/buildah)

set -euo pipefail

BUILDAH_DEB_PACKAGES_PATH="${1:?Argument missing: BuildahDebPackagesPath}"

echo "[BuildahInstall] Installing buildah packages from '$BUILDAH_DEB_PACKAGES_PATH'"
sudo DEBIAN_FRONTEND=noninteractive dpkg --force-confnew -i "$BUILDAH_DEB_PACKAGES_PATH"/*.deb
sudo DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y

echo "[BuildahInstall] Finished installing buildah"
