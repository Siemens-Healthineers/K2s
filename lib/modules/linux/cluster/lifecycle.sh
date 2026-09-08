#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

if [[ -n ${K2S_LIFECYCLE_SH_LOADED:-} ]]; then
  return 0
fi
readonly K2S_LIFECYCLE_SH_LOADED=1

k2s_dispatch_lifecycle() {
  local operation="$1"
  shift

  k2s_initialize_logging
  k2s_require_root || { k2s_log ERROR "Native Debian 13 $operation requires root privileges."; return 1; }
  k2s_require_install_dir || { k2s_log ERROR 'Native K2s installation directory is invalid.'; return 1; }

  local k2s_cli
  k2s_cli="$(k2s_install_path k2s)"
  if [[ ! -x "$k2s_cli" ]]; then
    k2s_log ERROR "Native K2s CLI is missing or not executable: $k2s_cli"
    return 1
  fi

  k2s_log INFO "Dispatching native Debian 13 $operation through the K2s CLI."
  exec "$k2s_cli" "$@"
}