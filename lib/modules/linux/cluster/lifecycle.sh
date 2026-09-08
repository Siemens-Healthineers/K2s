#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

if [[ -n ${K2S_LIFECYCLE_SH_LOADED:-} ]]; then
  return 0
fi
readonly K2S_LIFECYCLE_SH_LOADED=1

k2s_load_operation() {
  [[ "${1:-}" == '--operation-file' && -f "${2:-}" ]] || return 2
  [[ $(stat -c '%a' "$2") == 600 ]] || return 1
  K2S_INSTALL_DIR=$(jq -er '.installDir' "$2")
  K2S_CONFIG_DIR=$(jq -er '.configDir' "$2")
  K2S_VERSION=$(jq -r '.version // empty' "$2")
  K2S_CLUSTER_NAME=$(jq -r '.clusterName // "k2s-cluster"' "$2")
  K2S_CONTROL_PLANE_HOSTNAME=$(jq -r '.controlPlaneHostname // empty' "$2")
  K2S_PROXY=$(jq -r '.proxy // empty' "$2")
  K2S_NO_PROXY=$(jq -r '.noProxy // [] | join(",")' "$2")
  K2S_SKIP_START=$(jq -r '.skipStart // false' "$2")
  K2S_SKIP_PURGE=$(jq -r '.skipPurge // false' "$2")
  export K2S_INSTALL_DIR K2S_CONFIG_DIR K2S_VERSION K2S_CLUSTER_NAME K2S_CONTROL_PLANE_HOSTNAME K2S_PROXY K2S_NO_PROXY K2S_SKIP_START K2S_SKIP_PURGE
}

k2s_lock_and_run() {
  mkdir -p "$K2S_CONFIG_DIR" || return 1
  exec 9>"$K2S_CONFIG_DIR/lifecycle.lock"
  flock -w 300 9 || { k2s_log ERROR 'Timed out waiting for another K2s lifecycle operation.'; return 1; }
  "$@"
}
k2s_cfg() { jq -er "$1" "$K2S_INSTALL_DIR/cfg/config.json"; }
k2s_kubectl() { kubectl --kubeconfig /etc/kubernetes/admin.conf "$@"; }

k2s_merge_no_proxy() {
  local pod_cidr service_cidr
  pod_cidr=$(k2s_cfg '.smallsetup.podNetworkCIDR') || return 1
  service_cidr=$(k2s_cfg '.smallsetup.servicesCIDR') || return 1
  K2S_NO_PROXY=$(printf '%s\n' "${K2S_NO_PROXY//,/$'\n'}" localhost 127.0.0.1 ::1 "$pod_cidr" "$service_cidr" .svc .cluster.local | awk 'NF && !seen[$0]++' | paste -sd, -)
  export K2S_NO_PROXY
}

k2s_require_host() {
  k2s_require_root || return 3
  k2s_require_install_dir || return 1
  [[ $(. /etc/os-release; printf '%s-%s' "$ID" "$VERSION_ID") == debian-13* ]] || return 3
  local tool
  for tool in jq flock systemctl apt-get dpkg modprobe sysctl chattr lsattr ip; do
    k2s_require_command "$tool" || return 4
  done
  [[ $(wc -l < /proc/swaps) -le 1 ]] || return 3
}

k2s_proxy_network_install() {
  local address cidr; address=$(k2s_cfg '.smallsetup.kubeSwitch'); cidr=$(k2s_cfg '.smallsetup.masterNetworkCIDR')
  ip -o -4 addr show | grep -Fq "$address/" && ! ip -o -4 addr show dev k2s-proxy0 | grep -Fq "$address/" && return 5
  cat > /etc/systemd/system/k2s-proxy-network.service <<EOF
[Unit]
Description=K2s Linux-only proxy compatibility network
After=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -ec '/usr/sbin/ip link show k2s-proxy0 >/dev/null 2>&1 || /usr/sbin/ip link add k2s-proxy0 type dummy; /usr/sbin/ip addr replace $address/${cidr#*/} dev k2s-proxy0; /usr/sbin/ip link set k2s-proxy0 up'
ExecStop=/usr/sbin/ip link delete k2s-proxy0
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload || return 1
  systemctl enable --now k2s-proxy-network
}

k2s_proxy_install() {
  local gateway pod service primary args; gateway=$(k2s_cfg '.smallsetup.kubeSwitch'); pod=$(k2s_cfg '.smallsetup.podNetworkCIDR'); service=$(k2s_cfg '.smallsetup.servicesCIDR'); primary=$(ip -4 route get 1.1.1.1 | awk '/src/ {for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}')
  [[ -x "$K2S_INSTALL_DIR/bin/httpproxy" && -n "$primary" ]] || return 1
  args="--addr :8181 --allowed-cidr 127.0.0.0/8 --allowed-cidr $pod --allowed-cidr $service --allowed-cidr $(k2s_cfg '.smallsetup.masterNetworkCIDR') --allowed-cidr $primary/32"
  [[ -n "$K2S_PROXY" ]] && args="$args --forwardproxy $K2S_PROXY"
  mkdir -p /var/log/httpproxy /etc/apt/apt.conf.d
  cat > /etc/systemd/system/k2s-httpproxy.service <<EOF
[Unit]
Description=K2s local HTTP proxy
After=network-online.target k2s-proxy-network.service
Requires=k2s-proxy-network.service
[Service]
Type=simple
ExecStart=$K2S_INSTALL_DIR/bin/httpproxy $args
Environment="NO_PROXY=$K2S_NO_PROXY"
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
  printf '# Managed by K2s native Linux installation\nAcquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "http://$gateway:8181" "http://$gateway:8181" > /etc/apt/apt.conf.d/proxy.conf
  systemctl daemon-reload || return 1
  systemctl enable --now k2s-httpproxy
}

k2s_packages_install() {
  local version token gateway
  version=$(sed -n "/function Get-DefaultK8sVersion/,/^}/s/.*return ['\"]\(v[0-9][0-9.]*\)['\"].*/\1/p" "$K2S_INSTALL_DIR/lib/modules/windows/infra/k2s.infra.module/config/config.module.psm1" | head -1)
  token=$(tr -d '\r\n[:space:]' < "$K2S_INSTALL_DIR/bin/registry.dat")
  token=${token#$'\xEF\xBB\xBF'}
  printf '%s' "$token" | base64 -d >/dev/null 2>&1 || { k2s_log ERROR 'Packaged registry credential is not valid Base64.'; return 1; }
  gateway=$(k2s_cfg '.smallsetup.kubeSwitch')
  [[ -n "$token" && -n "$version" ]] || return 1
  K2S_VERSION="$version"
  export K2S_VERSION
  k2s_log INFO "Provisioning Kubernetes version $K2S_VERSION."
  mkdir -p "$K2S_CONFIG_DIR/packages"; chmod 700 "$K2S_CONFIG_DIR/packages"
  "$K2S_INSTALL_DIR/lib/scripts/linux/debian/linuxonly/ProvisionPackages.sh" download "$K2S_CONFIG_DIR/packages" "$version" "http://$gateway:8181" || return 1
  "$K2S_INSTALL_DIR/lib/scripts/linux/debian/linuxonly/ProvisionPackages.sh" install "$K2S_CONFIG_DIR/packages" "http://$gateway:8181" "$token" false "$K2S_NO_PROXY" true || return 1
  command -v kubeadm kubectl crictl crio >/dev/null || return 1
  systemctl enable --now crio || return 1
  crictl --runtime-endpoint unix:///var/run/crio/crio.sock version || return 1
  [[ $(kubeadm version -o short) == "$K2S_VERSION" ]] || return 1
  mkdir -p /var/log/kubelet /etc/systemd/system/kubelet.service.d
  printf '[Service]\nStandardOutput=append:/var/log/kubelet/kubelet.log\nStandardError=append:/var/log/kubelet/kubelet.log\n' > /etc/systemd/system/kubelet.service.d/20-k2s-logging.conf
  systemctl daemon-reload
}

k2s_control_plane_install() {
  local pod service cfg; pod=$(k2s_cfg '.smallsetup.podNetworkCIDR'); service=$(k2s_cfg '.smallsetup.servicesCIDR'); cfg=$(mktemp)
  cat > "$cfg" <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
nodeRegistration:
  criSocket: unix:///var/run/crio/crio.sock
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: $K2S_VERSION
networking:
  podSubnet: $pod
  serviceSubnet: $service
EOF
  systemctl enable --now crio || { rm -f "$cfg"; return 1; }
  kubeadm init --config="$cfg" || { rm -f "$cfg"; return 1; }
  rm -f "$cfg"
  systemctl enable kubelet || true
  local user="${SUDO_USER:-root}" home; home=$(getent passwd "$user" | cut -d: -f6); mkdir -p "$home/.kube"; cp /etc/kubernetes/admin.conf "$home/.kube/config"; chown -R "$user":"$(id -gn "$user")" "$home/.kube"
}

k2s_install_control_plane_tools() {
  local script="$K2S_INSTALL_DIR/lib/modules/windows/node/k2s.node.module/linuxnode/distros/scripts/install-cli-tools.sh"
  [[ -f "$script" ]] || return 1
  bash "$script" || return 1
  command -v helm yq >/dev/null
}

k2s_save_resolver() {
  [[ -e /etc/resolv.conf || -L /etc/resolv.conf ]] || return 1
  if [[ -L /etc/resolv.conf ]]; then
    jq -n --arg target "$(readlink /etc/resolv.conf)" '{type:"symlink",target:$target}' > "$K2S_CONFIG_DIR/dns-resolver-state.json"
  else
    jq -n --rawfile content /etc/resolv.conf '{type:"file",content:$content}' > "$K2S_CONFIG_DIR/dns-resolver-state.json"
  fi
  chmod 600 "$K2S_CONFIG_DIR/dns-resolver-state.json"
}

k2s_restore_resolver() {
  local state="$K2S_CONFIG_DIR/dns-resolver-state.json"
  [[ -f "$state" ]] || return 0
  chattr -i /etc/resolv.conf 2>/dev/null || true
  rm -f /etc/resolv.conf
  if [[ $(jq -r '.type' "$state") == symlink ]]; then
    ln -s "$(jq -r '.target' "$state")" /etc/resolv.conf
  else
    jq -r '.content' "$state" > /etc/resolv.conf
  fi
}

k2s_dns_start() {
  local gateway dns zones upstreams
  gateway=$(k2s_cfg '.smallsetup.kubeSwitch')
  k2s_kubectl -n kube-system rollout status deployment/coredns --timeout=120s || return 1
  dns=$(k2s_kubectl -n kube-system get service kube-dns -o jsonpath='{.spec.clusterIP}')
  zones=$(k2s_kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' | awk '/kubernetes / {for(i=2;i<=NF;i++)if($i!="{")print $i}')
  upstreams=$(resolvectl dns 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u || grep -E '^nameserver ' /etc/resolv.conf | awk '{print $2}')
  [[ -n "$dns" && -n "$zones" && -n "$upstreams" && -x "$K2S_INSTALL_DIR/bin/dnsproxy" ]] || return 1
  mkdir -p /etc/k2s /var/log/dnsproxy
  { printf '%s\n' '---' 'listen-addrs:' '  - "127.0.0.1"' "  - \"$gateway\"" 'listen-ports:' '  - 53' 'upstream:'; for zone in $zones; do printf '  - "[/%s/]%s"\n' "${zone%.}" "$dns"; done; for upstream in $upstreams; do printf '  - "%s"\n' "$upstream"; done; } > /etc/k2s/dnsproxy.yaml
  cat > /etc/systemd/system/k2s-dnsproxy.service <<EOF
[Unit]
Description=K2s DNS proxy
After=network-online.target kubelet.service
[Service]
Type=simple
ExecStart=$K2S_INSTALL_DIR/bin/dnsproxy --config-path=/etc/k2s/dnsproxy.yaml
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload || return 1
  systemctl enable --now k2s-dnsproxy || return 1
  printf '# Managed by K2s native Linux installation; restored by k2s stop or uninstall\nnameserver 127.0.0.1\n' > /etc/resolv.conf
  mkdir -p /etc/systemd/resolved.conf.d
  printf '# Managed by K2s native Linux installation\n[Resolve]\nDNS=127.0.0.1\nDomains=~.\n' > /etc/systemd/resolved.conf.d/20-k2s-dns.conf
  systemctl restart systemd-resolved || true
}

k2s_dns_stop() {
  rm -f /etc/systemd/resolved.conf.d/20-k2s-dns.conf
  systemctl stop k2s-dnsproxy 2>/dev/null || true
  systemctl restart systemd-resolved 2>/dev/null || true
  k2s_restore_resolver
}

k2s_install_cluster() {
  [[ ! -e /etc/kubernetes/admin.conf ]] || return 5
  k2s_log INFO 'Validating native Debian 13 host prerequisites.'
  k2s_require_host || return $?
  k2s_merge_no_proxy || return $?
  k2s_log INFO 'Configuring K2s proxy compatibility network.'
  k2s_proxy_network_install || return $?
  k2s_log INFO 'Configuring K2s HTTP proxy service.'
  k2s_proxy_install || return $?
  k2s_log INFO 'Provisioning Kubernetes and CRI-O packages.'
  k2s_packages_install || return $?
  k2s_log INFO 'Initializing the Kubernetes control plane.'
  k2s_control_plane_install || return $?
  local flannel="$K2S_INSTALL_DIR/lib/modules/windows/node/k2s.node.module/linuxnode/distros/containernetwork/masternode/flannel.template.yml"
  [[ -f "$flannel" ]] || return 1
  k2s_log INFO 'Deploying Flannel CNI.'
  sed -e 's|NETWORK.NAME|cbr0|g' -e "s|NETWORK.ADDRESS|$(k2s_cfg '.smallsetup.podNetworkCIDR')|g" -e 's|NETWORK.TYPE|vxlan|g' "$flannel" | k2s_kubectl apply -f - || return 1
  k2s_log INFO 'Waiting for Flannel CNI to become ready.'
  if ! k2s_kubectl -n kube-flannel rollout status daemonset/kube-flannel-ds --timeout=120s; then
    k2s_log ERROR 'Flannel did not become ready. Capturing pod and event diagnostics.'
    k2s_kubectl -n kube-flannel get pods -o wide 2>&1 | tee -a "$K2S_LOG_FILE" || true
    k2s_kubectl -n kube-flannel get events --sort-by=.lastTimestamp 2>&1 | tail -n 40 | tee -a "$K2S_LOG_FILE" || true
    return 1
  fi
  k2s_log INFO 'Deploying ClusterIP allocation webhook.'
  for manifest in namespace.yaml rbac.yaml webhook-config.yaml; do
    k2s_kubectl apply -f "$K2S_INSTALL_DIR/lib/manifests/clusterip-webhook/$manifest" || return 1
  done
  local deployment rendered_deployment linux_service windows_service
  deployment="$K2S_INSTALL_DIR/lib/manifests/clusterip-webhook/deployment.yaml"
  linux_service=$(k2s_cfg '.smallsetup.servicesCIDRLinux') || return 1
  windows_service=$(k2s_cfg '.smallsetup.servicesCIDRWindows') || return 1
  rendered_deployment=$(mktemp)
  sed "s|--linux-subnet=172.21.0.0/24|--linux-subnet=$linux_service|;s|--windows-subnet=172.21.1.0/24|--windows-subnet=$windows_service|" "$deployment" > "$rendered_deployment" || return 1
  k2s_kubectl apply -f "$rendered_deployment" || { rm -f "$rendered_deployment"; return 1; }
  rm -f "$rendered_deployment"
  if ! k2s_kubectl -n k2s-webhook rollout status deployment/clusterip-webhook --timeout=120s; then
    k2s_log ERROR 'ClusterIP webhook rollout did not complete. Capturing pod and event diagnostics.'
    k2s_kubectl -n k2s-webhook get pods -o wide 2>&1 | tee -a "$K2S_LOG_FILE" || true
    k2s_kubectl -n k2s-webhook get events --sort-by=.lastTimestamp 2>&1 | tail -n 40 | tee -a "$K2S_LOG_FILE" || true
    return 1
  fi
  k2s_log INFO 'Installing bundled Linux control-plane tools.'
  k2s_install_control_plane_tools || return $?
  k2s_kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
  k2s_log INFO 'Configuring K2s host DNS proxy.'
  k2s_save_resolver || return 1
  k2s_dns_start || { k2s_restore_resolver; return 1; }
  jq -n --arg v "$K2S_VERSION" --arg n "$K2S_CLUSTER_NAME" --arg h "$K2S_CONTROL_PLANE_HOSTNAME" '{SetupType:"k2s",LinuxOnly:true,Version:$v,ClusterName:$n,ControlPlaneNodeHostname:$h,WSL:false}' > "$K2S_CONFIG_DIR/setup.json"; chmod 644 "$K2S_CONFIG_DIR/setup.json"
}

k2s_start_cluster() {
  k2s_log INFO 'Starting native Debian 13 K2s services.'
  systemctl start k2s-proxy-network || return 1
  systemctl start k2s-httpproxy || return 1
  systemctl start crio || return 1
  systemctl start kubelet || return 1
  local end=$((SECONDS + 60))
  until k2s_kubectl cluster-info >/dev/null 2>&1; do
    (( SECONDS < end )) || return 1
    sleep 3
  done
  k2s_dns_start
}
k2s_stop_cluster() { k2s_dns_stop; systemctl stop kubelet 2>/dev/null || true; systemctl stop crio k2s-httpproxy k2s-proxy-network 2>/dev/null || true; }
k2s_uninstall_cluster() { k2s_stop_cluster; if [[ "$K2S_SKIP_PURGE" != true ]]; then k2s_kubectl delete namespace k2s-webhook --ignore-not-found --wait=false 2>/dev/null || true; kubeadm reset -f 2>/dev/null || true; rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet /etc/cni/net.d/10-flannel.conflist /run/flannel; fi; ip link delete cni0 2>/dev/null || true; ip link delete flannel.1 2>/dev/null || true; rm -f /etc/systemd/system/k2s-{httpproxy,dnsproxy,proxy-network}.service /etc/apt/apt.conf.d/proxy.conf /etc/systemd/system/kubelet.service.d/20-k2s-logging.conf; systemctl daemon-reload || true; rm -rf "$K2S_CONFIG_DIR"; }

k2s_dispatch_lifecycle() {
  local operation="$1"
  shift

  k2s_load_operation "$@" || return $?
  k2s_initialize_logging
  k2s_log INFO "Starting native Debian 13 lifecycle operation: $operation"
  trap 'exit_code=$?; k2s_log ERROR "Native Debian 13 lifecycle operation failed at shell line $LINENO (exit code $exit_code)"' ERR
  if k2s_lock_and_run "k2s_${operation}_cluster"; then
    k2s_log INFO "Completed native Debian 13 lifecycle operation: $operation"
  else
    local exit_code=$?
    k2s_log ERROR "Native Debian 13 lifecycle operation failed: $operation (exit code $exit_code)"
    return "$exit_code"
  fi
}
