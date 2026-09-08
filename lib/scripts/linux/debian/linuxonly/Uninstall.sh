#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export K2S_INSTALL_DIR="${K2S_INSTALL_DIR:-$(cd "$script_dir/../../../../../" && pwd)}"
export K2S_LOG_FILE="${K2S_LOG_FILE:-/var/log/k2s.log}"

source "$K2S_INSTALL_DIR/lib/modules/linux/common/logging.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/common/validation.sh"

k2s_initialize_logging
k2s_require_root || { k2s_log ERROR 'Native Debian 13 uninstall requires root privileges.'; exit 1; }

k2s_cli="$K2S_INSTALL_DIR/k2s"
if [[ ! -x "$k2s_cli" ]]; then
  k2s_log ERROR "Native K2s CLI is missing or not executable: $k2s_cli"
  exit 1
fi

k2s_log INFO 'Dispatching native Debian 13 uninstall through the K2s CLI.'
exec "$k2s_cli" uninstall "$@"