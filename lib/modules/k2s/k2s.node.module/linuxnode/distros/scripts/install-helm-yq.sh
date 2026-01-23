#!/bin/bash
# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT
set -e


# Try to get proxy from apt or environment
PROXY=""
if [ -f /etc/apt/apt.conf.d/proxy.conf ]; then
    PROXY=$(grep -i 'Acquire::http::Proxy' /etc/apt/apt.conf.d/proxy.conf | awk -F'"' '{print $2}')
fi
if [ -z "$PROXY" ] && grep -qi 'http_proxy' /etc/environment; then
    PROXY=$(grep -i 'http_proxy' /etc/environment | awk -F'=' '{print $2}' | tr -d '"')
fi

echo "Proxy detected: $PROXY"

# Set curl proxy option if proxy is set
CURL_PROXY_OPT=""
if [ -n "$PROXY" ]; then
    CURL_PROXY_OPT="--proxy $PROXY"
fi

# Install yq
if ! command -v yq &> /dev/null; then
    echo "Installing yq..."
    YQ_VERSION="v4.47.1"
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        ARCH="amd64"
    fi
    sudo curl -L $CURL_PROXY_OPT -o /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${ARCH}" --silent
    sudo chmod +x /usr/local/bin/yq
    yq --version
else
    echo "yq already installed"
fi

# Install helm
if ! command -v helm &> /dev/null; then
    echo "Installing helm..."
    HELM_VERSION="v4.1.0"
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        ARCH="amd64"
    fi
    curl -L $CURL_PROXY_OPT -o "helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" --silent
    tar -xzf "helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
    sudo mv "linux-${ARCH}/helm" /usr/local/bin/helm
    sudo chmod +x /usr/local/bin/helm
    rm -rf "helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" "linux-${ARCH}"
    helm version
else
    echo "helm already installed"
fi