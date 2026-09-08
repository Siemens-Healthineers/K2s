#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

if [[ -n ${K2S_COMMAND_SH_LOADED:-} ]]; then
  return 0
fi
readonly K2S_COMMAND_SH_LOADED=1

k2s_run() {
  local command_line
  printf -v command_line '%q ' "$@"
  k2s_log INFO "Running command: ${command_line% }"

  if "$@" 2>&1 | tee -a "$K2S_LOG_FILE"; then
    return 0
  else
    local exit_code=${PIPESTATUS[0]}
    k2s_log_command_failure "$exit_code" "${command_line% }"
    return "$exit_code"
  fi
}