#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

if [[ -n ${K2S_LOGGING_SH_LOADED:-} ]]; then
  return 0
fi
readonly K2S_LOGGING_SH_LOADED=1

: "${K2S_LOG_FILE:=/var/log/k2s.log}"

k2s_initialize_logging() {
  local log_directory
  log_directory=$(dirname "$K2S_LOG_FILE")
  mkdir -p "$log_directory"
  touch "$K2S_LOG_FILE"
  chmod 0644 "$K2S_LOG_FILE"
}

k2s_log() {
  local level="$1"
  shift

  local message="$(date -Is) [$level] $*"
  printf '%s\n' "$message" >> "$K2S_LOG_FILE"
  if [[ "$level" == "ERROR" || "$level" == "WARN" ]]; then
    printf '%s\n' "$message" >&2
  else
    printf '%s\n' "$message"
  fi
}

k2s_log_command_failure() {
  local exit_code="$1"
  shift
  k2s_log ERROR "Command failed with exit code $exit_code: $*"
}