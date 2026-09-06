#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

if [[ -n ${K2S_DNS_SH_LOADED:-} ]]; then
  return 0
fi
readonly K2S_DNS_SH_LOADED=1

readonly K2S_DNS_RESOLVED_DROP_IN='/etc/systemd/resolved.conf.d/20-k2s-dns.conf'

k2s_configure_systemd_resolved_dns() {
  local dns_server="$1"
  local dns_domain="$2"
  local content="[Resolve]
DNS=$dns_server
Domains=$dns_domain"

  k2s_write_managed_file "$K2S_DNS_RESOLVED_DROP_IN" 0644 "$content"
  k2s_run systemctl restart systemd-resolved
}

k2s_remove_systemd_resolved_dns() {
  if [[ -f "$K2S_DNS_RESOLVED_DROP_IN" ]]; then
    rm -f "$K2S_DNS_RESOLVED_DROP_IN"
    k2s_log INFO "Removed managed DNS configuration: $K2S_DNS_RESOLVED_DROP_IN"
    k2s_run systemctl restart systemd-resolved
  fi
}