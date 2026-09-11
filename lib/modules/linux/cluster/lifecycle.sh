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
  jq -e '(.installDir | type == "string" and length > 0) and (.configDir | type == "string" and length > 0) and ((.noProxy // []) | type == "array") and ((.skipStart // false) | type == "boolean") and ((.skipPurge // false) | type == "boolean")' "$2" >/dev/null || return 2
  K2S_INSTALL_DIR=$(jq -er '.installDir' "$2") || return 2
  K2S_CONFIG_DIR=$(jq -er '.configDir' "$2") || return 2
  K2S_VERSION=$(jq -r '.version // empty' "$2") || return 2
  K2S_CLUSTER_NAME=$(jq -r '.clusterName // "k2s-cluster"' "$2") || return 2
  K2S_CONTROL_PLANE_HOSTNAME=$(jq -r '.controlPlaneHostname // empty' "$2") || return 2
  K2S_CONTROL_PLANE_HOSTNAME=${K2S_CONTROL_PLANE_HOSTNAME:-$(hostname)}
  K2S_PROXY=$(jq -r '.proxy // empty' "$2") || return 2
  K2S_NO_PROXY=$(jq -r '.noProxy // [] | join(",")' "$2") || return 2
  K2S_SKIP_START=$(jq -r '.skipStart // false' "$2") || return 2
  K2S_SKIP_PURGE=$(jq -r '.skipPurge // false' "$2") || return 2
  K2S_LINUX_ONLY=$(jq -r '.linuxOnly // false' "$2") || return 2
  K2S_WORKER_CPU_COUNT=$(jq -r '.workerCPUCount // "4"' "$2") || return 2
  K2S_WORKER_MEMORY=$(jq -r '.workerMemory // "8GB"' "$2") || return 2
  K2S_WORKER_DISK_SIZE=$(jq -r '.workerDiskSize // "64GB"' "$2") || return 2
  K2S_WINDOWS_ISO_PATH=$(jq -r '.windowsIsoPath // empty' "$2") || return 2
  export K2S_INSTALL_DIR K2S_CONFIG_DIR K2S_VERSION K2S_CLUSTER_NAME K2S_CONTROL_PLANE_HOSTNAME K2S_PROXY K2S_NO_PROXY K2S_SKIP_START K2S_SKIP_PURGE K2S_LINUX_ONLY K2S_WORKER_CPU_COUNT K2S_WORKER_MEMORY K2S_WORKER_DISK_SIZE K2S_WINDOWS_ISO_PATH
}

k2s_lock_and_run() {
  mkdir -p "$K2S_CONFIG_DIR" || return 1
  exec 9>"$K2S_CONFIG_DIR/lifecycle.lock"
  flock -w 300 9 || { k2s_log ERROR 'Timed out waiting for another K2s lifecycle operation.'; return 1; }
  "$@"
  local exit_code=$?
  flock -u 9
  exec 9>&-
  return "$exit_code"
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

k2s_windows_worker_install() {
  [[ "$K2S_LINUX_ONLY" == true ]] || k2s_windows_worker_provision
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

k2s_install_cluster() {
  [[ ! -e /etc/kubernetes/admin.conf ]] || return 5
  k2s_log INFO 'Validating native Debian 13 host prerequisites.'
  k2s_require_host || return $?
  k2s_merge_no_proxy || return $?
  k2s_log INFO 'Configuring K2s proxy compatibility network.'
  k2s_proxy_network_install || return $?
  k2s_log INFO 'Configuring K2s HTTP proxy service.'
  k2s_proxy_install || return $?
  if [[ "$K2S_LINUX_ONLY" != true ]]; then
    k2s_windows_worker_install_host_dependencies || return $?
  fi
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
  k2s_windows_worker_install || return $?
  jq -n --arg v "$K2S_VERSION" --arg n "$K2S_CLUSTER_NAME" --arg h "$K2S_CONTROL_PLANE_HOSTNAME" --argjson linux_only "$K2S_LINUX_ONLY" '{SetupType:"k2s",LinuxOnly:$linux_only,Version:$v,ClusterName:$n,ControlPlaneNodeHostname:$h,WSL:false}' > "$K2S_CONFIG_DIR/setup.json"; chmod 644 "$K2S_CONFIG_DIR/setup.json"
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
  [[ "$K2S_LINUX_ONLY" == true ]] || k2s_windows_worker_start
}
k2s_stop_cluster() { [[ "$K2S_LINUX_ONLY" == true ]] || k2s_windows_worker_stop || true; k2s_dns_stop; systemctl stop kubelet 2>/dev/null || true; systemctl stop crio k2s-httpproxy k2s-proxy-network 2>/dev/null || true; }
k2s_uninstall_cluster() {
  if [[ "$K2S_SKIP_PURGE" != true ]]; then
    # Keep the API server available long enough to remove all node records.
    # kubeadm reset clears host files but does not remove Nodes from the API.
    [[ "$K2S_LINUX_ONLY" == true ]] || k2s_windows_worker_stop || true
    k2s_kubectl delete nodes --all --ignore-not-found --wait=true --timeout=60s 2>/dev/null || true
    k2s_kubectl delete namespace k2s-webhook kube-flannel --ignore-not-found --wait=true --timeout=120s 2>/dev/null || true
  fi
  k2s_stop_cluster || return $?
  [[ "$K2S_LINUX_ONLY" == true ]] || k2s_windows_worker_remove || true
  if [[ "$K2S_SKIP_PURGE" != true ]]; then
    kubeadm reset -f 2>/dev/null || true
    rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet /etc/cni/net.d/10-flannel.conflist /run/flannel
  fi
  ip link delete cni0 2>/dev/null || true
  ip link delete flannel.1 2>/dev/null || true
  rm -f /etc/systemd/system/k2s-dnsproxy.service /etc/k2s/dnsproxy.yaml /etc/systemd/system/kubelet.service.d/20-k2s-logging.conf
  k2s_proxy_cleanup || return $?
  rm -rf "$K2S_CONFIG_DIR"
}

k2s_dispatch_lifecycle() {
  local operation="$1"
  shift

  k2s_load_operation "$@" || return $?
  k2s_initialize_logging
  k2s_log INFO "Starting native Debian 13 lifecycle operation: $operation"
  export K2S_LOG_STREAMED=true
  exec > >(tee -a "$K2S_LOG_FILE") 2>&1
  trap 'exit_code=$?; k2s_log ERROR "Native Debian 13 lifecycle operation failed at shell line $LINENO (exit code $exit_code)"' ERR
  if k2s_lock_and_run "k2s_${operation}_cluster"; then
    k2s_log INFO "Completed native Debian 13 lifecycle operation: $operation"
  else
    local exit_code=$?
    k2s_log ERROR "Native Debian 13 lifecycle operation failed: $operation (exit code $exit_code)"
    return "$exit_code"
  fi
}
