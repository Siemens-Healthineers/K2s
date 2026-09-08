#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

required_files=(
  "lib/scripts/linux/debian/host/Install.sh"
  "lib/scripts/linux/debian/host/Start.sh"
  "lib/scripts/linux/debian/host/Stop.sh"
  "lib/scripts/linux/debian/host/Status.sh"
  "lib/scripts/linux/debian/host/Uninstall.sh"
  "lib/scripts/linux/debian/linuxonly/Install.sh"
  "lib/scripts/linux/debian/linuxonly/Start.sh"
  "lib/scripts/linux/debian/linuxonly/Stop.sh"
  "lib/scripts/linux/debian/linuxonly/Status.sh"
  "lib/scripts/linux/debian/linuxonly/Uninstall.sh"
  "lib/scripts/linux/debian/linuxonly/ProvisionPackages.sh"
  "lib/modules/linux/common/logging.sh"
  "lib/modules/linux/common/command.sh"
  "lib/modules/linux/common/paths.sh"
  "lib/modules/linux/common/validation.sh"
  "lib/modules/linux/cluster/lifecycle.sh"
  "cfg/nodeextension/debian13/scripts/download-k8s-packages.sh"
  "cfg/nodeextension/debian13/scripts/install-k8s-packages.sh"
)

for relative_path in "${required_files[@]}"; do
  path="$repo_root/$relative_path"
  if [[ ! -f "$path" ]]; then
    printf 'error: required native Linux path is missing: %s\n' "$relative_path" >&2
    exit 1
  fi
  bash -n "$path"
done

for operation in Install Start Stop Status Uninstall; do
  if ! grep -Fq "../linuxonly/${operation}.sh" "$repo_root/lib/scripts/linux/debian/host/${operation}.sh"; then
    printf 'error: host %s entry point does not delegate to Linux-only lifecycle\n' "$operation" >&2
    exit 1
  fi
done

printf '%s\n' 'Native Debian 13 lifecycle layout validation passed.'