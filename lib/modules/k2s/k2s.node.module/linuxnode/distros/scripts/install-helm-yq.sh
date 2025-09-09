#!/bin/bash
set -e

# Set proxy (hardcoded, as in install_go.sh)
PROXY="http://172.19.1.1:8181"

# Install yq
if ! command -v yq &> /dev/null; then
    echo "Installing yq..."
    YQ_VERSION="v4.43.1"
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        ARCH="amd64"
    fi
    sudo curl -L --proxy $PROXY -o /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${ARCH}"
    sudo chmod +x /usr/local/bin/yq
    yq --version
else
    echo "yq already installed"
fi

# Install helm
if ! command -v helm &> /dev/null; then
    echo "Installing helm..."
    HELM_VERSION="v3.14.4"
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        ARCH="amd64"
    fi
    curl -L --proxy $PROXY -o "helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
    tar -xzf "helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
    sudo mv "linux-${ARCH}/helm" /usr/local/bin/helm
    sudo chmod +x /usr/local/bin/helm
    rm -rf "helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" "linux-${ARCH}"
    helm version
else
    echo "helm already installed"
fi