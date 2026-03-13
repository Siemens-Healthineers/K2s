#!/bin/bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

set -euo pipefail

BUILDAH_DEB_PACKAGES_PATH="${1:?Argument missing: BuildahDebPackagesPath}"

echo "[BuildahInstall] Installing buildah packages from '$BUILDAH_DEB_PACKAGES_PATH'"

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

echo "[BuildahInstall] Finished installing buildah"
