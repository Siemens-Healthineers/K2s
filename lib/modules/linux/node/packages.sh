#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

if [[ -n ${K2S_NODE_PACKAGES_SH_LOADED:-} ]]; then
  return 0
fi
readonly K2S_NODE_PACKAGES_SH_LOADED=1

k2s_wait_for_dpkg_lock() {
  local timeout_seconds="${1:-300}"
  local deadline=$((SECONDS + timeout_seconds))

  while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      k2s_log ERROR "Timed out waiting for the Debian package manager lock after ${timeout_seconds}s"
      return 1
    fi
    k2s_log INFO 'Waiting for the Debian package manager lock.'
    sleep 5
  done
}

k2s_install_debian_packages() {
  local package_directory="$1"
  k2s_require_directory "$package_directory" || return 1
  k2s_wait_for_dpkg_lock || return 1
  k2s_run env DEBIAN_FRONTEND=noninteractive dpkg -i "$package_directory"/*.deb || true
  k2s_run env DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y
}