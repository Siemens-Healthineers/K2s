#!/bin/bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

set -euo pipefail

BUILDAH_DEB_PACKAGES_PATH="${1:?Argument missing: BuildahDebPackagesPath}"

echo "[BuildahInstall] Installing buildah packages from '$BUILDAH_DEB_PACKAGES_PATH'"
# Allow dpkg to partially fail (e.g. crun post-install errors) so that
# apt-get --fix-broken can repair the broken state afterwards.
sudo DEBIAN_FRONTEND=noninteractive dpkg --force-confnew -i "$BUILDAH_DEB_PACKAGES_PATH"/*.deb || true
sudo DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y

echo "[BuildahInstall] Finished installing buildah"
