#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

set -euo pipefail

usage() {
  printf '%s\n' 'Usage: ProvisionPackages.sh <download|install> <arguments...>' >&2
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export K2S_INSTALL_DIR="${K2S_INSTALL_DIR:-$(cd "$script_dir/../../../../../" && pwd)}"
export K2S_LOG_FILE="${K2S_LOG_FILE:-/var/log/k2s.log}"

source "$K2S_INSTALL_DIR/lib/modules/linux/common/logging.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/common/validation.sh"

k2s_initialize_logging
k2s_require_root || { k2s_log ERROR 'Native Debian 13 package provisioning requires root privileges.'; exit 1; }

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

operation="$1"
shift
node_extension_dir="$K2S_INSTALL_DIR/cfg/nodeextension/debian13/scripts"

case "$operation" in
  download)
    target_script="$node_extension_dir/download-k8s-packages.sh"
    ;;
  install)
    target_script="$node_extension_dir/install-k8s-packages.sh"
    ;;
  *)
    usage
    exit 2
    ;;
esac

k2s_require_file "$target_script" || exit 1
k2s_log INFO "Dispatching native Debian 13 package $operation through node-extension assets."
exec bash "$target_script" "$@"