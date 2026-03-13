#!/bin/bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

set -euo pipefail

BUILDAH_DEB_PACKAGES_PATH="${1:?Argument missing: BuildahDebPackagesPath}"

echo "[BuildahInstall] Installing buildah packages from '$BUILDAH_DEB_PACKAGES_PATH'"

# dpkg installs packages in the order the shell glob expands (alphabetical).
# A package like libgpgme11 may appear before its own deps (gnupg, libassuan0),
# leaving it unconfigured after pass 1. Running dpkg -i multiple times lets
# each pass configure packages whose deps are now satisfied by the previous pass.
# --no-remove prevents apt --fix-broken from evicting buildah when the fresh
# node has not yet configured all of buildah's transitively-needed packages.
for pass in 1 2 3; do
    echo "[BuildahInstall] dpkg install pass $pass"
    sudo DEBIAN_FRONTEND=noninteractive dpkg --force-confnew -i "$BUILDAH_DEB_PACKAGES_PATH"/*.deb 2>&1 || true
done

# Repair any remaining dependency issues but do NOT remove packages.
sudo DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y --no-remove 2>&1 || true

# Verify buildah is actually usable - this is the definitive success check.
if ! sudo buildah --version > /dev/null 2>&1; then
    echo "[BuildahInstall] ERROR: buildah is not functional after installation"
    exit 1
fi

echo "[BuildahInstall] Finished installing buildah"
