#!/bin/bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT
#
# install-k8s-packages.sh

set -euo pipefail

K8S_DEB_PACKAGES_PATH="${1:?Argument missing: K8sDebPackagesPath}"
PROXY="${2:-}"
REGISTRY_TOKEN="${3:?Argument missing: RegistryToken}"
IS_WSL="${4:-false}"

echo "[InstallK8s] Starting Kubernetes artifacts installation"
echo "[InstallK8s] Packages path: $K8S_DEB_PACKAGES_PATH"

# ---------------------------------------------------------------------------
# Validate packages directory
# ---------------------------------------------------------------------------
if ! ls "$K8S_DEB_PACKAGES_PATH" > /dev/null 2>&1; then
    echo "[InstallK8s] ERROR: The directory '$K8S_DEB_PACKAGES_PATH' does not exist. Cannot install Kubernetes artifacts." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Install .deb packages
# ---------------------------------------------------------------------------
echo "[InstallK8s] Installing deb packages from $K8S_DEB_PACKAGES_PATH"
sudo DEBIAN_FRONTEND=noninteractive dpkg -i "$K8S_DEB_PACKAGES_PATH"/*.deb || true
sudo DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y

# ---------------------------------------------------------------------------
# Configure bridged traffic (kernel modules + sysctl)
# ---------------------------------------------------------------------------
echo "[InstallK8s] Configuring bridged traffic"
echo overlay   | sudo tee /etc/modules-load.d/k8s.conf
echo br_netfilter | sudo tee /etc/modules-load.d/k8s.conf
sudo modprobe overlay
sudo modprobe br_netfilter

echo 'net.bridge.bridge-nf-call-ip6tables = 1' | sudo tee -a /etc/sysctl.d/k8s.conf
echo 'net.bridge.bridge-nf-call-iptables = 1'  | sudo tee -a /etc/sysctl.d/k8s.conf
echo 'net.ipv4.ip_forward = 1'                  | sudo tee -a /etc/sysctl.d/k8s.conf
sudo sysctl --system

# ---------------------------------------------------------------------------
# Ensure shared mount on reboot
# ---------------------------------------------------------------------------
echo '@reboot root mount --make-rshared /' | sudo tee /etc/cron.d/sharedmount

# ---------------------------------------------------------------------------
# Hold cri-o to prevent unintended upgrades
# ---------------------------------------------------------------------------
sudo apt-mark hold cri-o

# ---------------------------------------------------------------------------
# Configure crictl timeout
# ---------------------------------------------------------------------------
sudo touch /etc/crictl.yaml
if grep -q 'timeout' /etc/crictl.yaml; then
    sudo sed -i 's/timeout.*/timeout: 30/g' /etc/crictl.yaml
else
    echo 'timeout: 30' | sudo tee -a /etc/crictl.yaml
fi

# ---------------------------------------------------------------------------
# Proxy configuration for CRI-O (optional)
# ---------------------------------------------------------------------------
if [ -n "$PROXY" ]; then
    echo "[InstallK8s] Configuring CRI-O proxy: $PROXY"
    sudo mkdir -p /etc/systemd/system/crio.service.d
    sudo touch /etc/systemd/system/crio.service.d/http-proxy.conf
    {
        echo '[Service]'
        echo "Environment='HTTP_PROXY=$PROXY'"
        echo "Environment='HTTPS_PROXY=$PROXY'"
        echo "Environment='http_proxy=$PROXY'"
        echo "Environment='https_proxy=$PROXY'"
        echo "Environment='no_proxy=.local'"
    } | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf
fi

# ---------------------------------------------------------------------------
# Container registry authentication (shsk2s.azurecr.io)
# ---------------------------------------------------------------------------
echo "[InstallK8s] Configuring container registry authentication"
cat <<EOF | sudo tee /tmp/auth.json > /dev/null
{
  "auths": {
    "shsk2s.azurecr.io": {
      "auth": "$REGISTRY_TOKEN"
    }
  }
}
EOF
sudo mkdir -p /root/.config/containers
sudo mv /tmp/auth.json /root/.config/containers/auth.json

# ---------------------------------------------------------------------------
# Configure CRI-O: lower priority of default CNI bridge
# ---------------------------------------------------------------------------
echo "[InstallK8s] Configure CRI-O"
# cri-o default cni bridge should have least priority
CRIO_CNI_FILE='/etc/cni/net.d/10-crio-bridge.conf'
if [ -f "$CRIO_CNI_FILE" ]; then
    sudo mv "$CRIO_CNI_FILE" /etc/cni/net.d/100-crio-bridge.conf
else
    echo "[InstallK8s] File does not exist, no renaming of cni file $CRIO_CNI_FILE.."
fi

echo 'unqualified-search-registries = ["docker.io", "quay.io"]' | sudo tee -a /etc/containers/registries.conf

# ---------------------------------------------------------------------------
# Hold kubelet, kubeadm, kubectl
# ---------------------------------------------------------------------------
sudo apt-mark hold kubelet kubeadm kubectl

# ---------------------------------------------------------------------------
# Start CRI-O
# ---------------------------------------------------------------------------
echo "[InstallK8s] Starting CRI-O"
sudo systemctl daemon-reload
sudo systemctl enable crio || true
sudo systemctl start crio

# ---------------------------------------------------------------------------
# WSL-specific CRI-O fix (optional)
# ---------------------------------------------------------------------------
if [ "$IS_WSL" = "true" ]; then
    echo "[InstallK8s] Applying CRI-O WSL fix"
    CONFIG_WSL='/etc/crio/crio.conf.d/20-wsl.conf'
    {
        echo '[crio.runtime]'
        echo 'add_inheritable_capabilities=true'
        echo 'default_sysctls=["net.ipv4.ip_unprivileged_port_start=0"]'
    } | sudo tee -a "$CONFIG_WSL" > /dev/null
    sudo systemctl restart crio
fi

echo "[InstallK8s] Kubernetes artifacts installation completed successfully"
