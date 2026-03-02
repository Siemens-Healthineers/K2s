#!/bin/bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

set -euo pipefail

BUILDAH_DEB_PACKAGES_PATH="${1:?Argument missing: BuildahDebPackagesPath}"

echo "[BuildahInstall] Installing buildah packages from '$BUILDAH_DEB_PACKAGES_PATH'"
# Allow dpkg to partially fail (e.g. optional Recommends deps with post-install
# issues) so that apt-get --fix-broken can repair the broken state afterwards.
sudo DEBIAN_FRONTEND=noninteractive dpkg --force-confnew -i "$BUILDAH_DEB_PACKAGES_PATH"/*.deb || true
sudo DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y || true

# Verify buildah is actually usable - this is the definitive success check.
if ! sudo buildah --version > /dev/null 2>&1; then
    echo "[BuildahInstall] ERROR: buildah is not functional after installation"
    exit 1
fi

echo "[BuildahInstall] Finished installing buildah"
