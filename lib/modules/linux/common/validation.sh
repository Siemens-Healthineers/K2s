#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

if [[ -n ${K2S_VALIDATION_SH_LOADED:-} ]]; then
  return 0
fi
readonly K2S_VALIDATION_SH_LOADED=1

k2s_require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    printf '%s\n' 'K2s Linux host operations must be run as root.' >&2
    return 1
  fi
}

k2s_require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Required command is not available: %s\n' "$command_name" >&2
    return 1
  fi
}

k2s_require_file() {
  local file_path="$1"
  if [[ ! -f "$file_path" ]]; then
    printf 'Required file does not exist: %s\n' "$file_path" >&2
    return 1
  fi
}

k2s_require_directory() {
  local directory_path="$1"
  if [[ ! -d "$directory_path" ]]; then
    printf 'Required directory does not exist: %s\n' "$directory_path" >&2
    return 1
  fi
}