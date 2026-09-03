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

  "$@"
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    k2s_log_command_failure "$exit_code" "${command_line% }"
    return "$exit_code"
  fi
}