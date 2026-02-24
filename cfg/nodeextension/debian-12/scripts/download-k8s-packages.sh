#!/bin/bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

# Arguments from PowerShell
TARGET_PATH="$1"
K8S_VERSION="$2"
PROXY="${3:-}"

# Setup functions
log_info() {
    echo "[K8sPackages] $1"
}

log_warning() {
    echo "[K8sPackages] WARNING: $1"
}

cleanup_and_create() {
    local path="$1"
    if [ -d "$path" ]; then
        rm -rf "$path"
    fi
    mkdir -p "$path"
}

# Main execution
log_info "Starting Kubernetes package download"
log_info "Target path: $TARGET_PATH"
log_info "K8s version: $K8S_VERSION"

# Setup paths
cleanup_and_create "$TARGET_PATH"

# # APT sandbox config
echo "APT::Sandbox::User \"root\";" | sudo tee /etc/apt/apt.conf.d/10sandbox-for-k2s > /dev/null

# Copy ZScaler certificate (if exists)
if [ -f /tmp/ZScalerRootCA.crt ]; then
    log_info "Adding ZScaler certificate"
    sudo mv /tmp/ZScalerRootCA.crt /usr/local/share/ca-certificates/
    sudo update-ca-certificates
fi

download_packages() {
    local package_name="$1"
    # Strip version for apt-cache query (e.g., "kubelet=1.35.0-1.1" -> "kubelet")
    local pkg_base="${package_name%%=*}"
    
    log_info "Downloading: $package_name"
    # Download the main package directly
    cd "$TARGET_PATH" && sudo apt-get download "$package_name" 2>/dev/null || true
    
    # Get direct dependencies from repository metadata (works regardless of install state)
    # Use pkg_base (without version) because apt-cache depends doesn't support =version syntax
    # Filter out Debian base system packages that are always present in the VM
    apt-cache depends --no-recommends "$pkg_base" 2>/dev/null | \
        grep -E "^\s+(Depends|PreDepends):" | \
        sed 's/^[[:space:]]*[^:]*:[[:space:]]*//' | \
        grep -v '^$' | sort -u | while read dep; do
            # Skip packages already in Debian 12 base image
            case "$dep" in
                apt|systemd|systemd-sysv|libc6|util-linux|mount|iptables|openssl| \
                libbz2-1.0|libgcrypt20|libgpg-error0|libreadline8|libsqlite3-0|zlib1g| \
                debconf|cdebconf|curl|init-system-helpers|adduser|libip*|libnetfilter*| \
                libnfnetlink*|libnftables*|nftables|libxtables*|libmnl*|libcap2*)
                    continue
                    ;;
            esac
            if ! ls "${TARGET_PATH}/${dep}"_*.deb >/dev/null 2>&1; then
                log_info "  Downloading dependency: $dep"
                cd "$TARGET_PATH" && sudo apt-get download "$dep" 2>/dev/null || true
            fi
        done

}

log_info "=== Downloading Base Tools ==="
download_packages 'gpg'
download_packages 'apt-transport-https'
download_packages 'ca-certificates'

set_kubernetes_apt_repository() {
    local K8S_VERSION="$1"
    local PROXY="${2:-}"
    local MAX_RETRIES=2

    log_info "Step 1: Update package list (required before installing anything)"
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq --yes --allow-releaseinfo-change 2>&1 | grep -v "^Reading" | grep -v "^Building" || true
    
    log_info "Step 2: Install required tools (gpg and curl)"
    # Install GPG with retry and repair logic
    install_with_retry "gpg" "$MAX_RETRIES"
    
    # Install curl with retry and repair logic
    install_with_retry "curl" "$MAX_RETRIES"
    
    log_info "Step 3: Download and configure Kubernetes and CRI-O repositories"

    # Setup proxy flag if provided
    PROXY_FLAG=""
    if [ -n "$PROXY" ]; then
        PROXY_FLAG="--proxy $PROXY"
    fi

    KUBERNETES_APT_KEYRING='/usr/share/keyrings/kubernetes-apt-keyring.gpg'
    
    # Clean up old keyring file
    sudo rm -f "$KUBERNETES_APT_KEYRING"
    
    # Download and convert Kubernetes GPG key in one pipeline (soft failure - continues if 403)
    log_info "Downloading and converting Kubernetes GPG key"
    if sudo curl -fsSL $PROXY_FLAG "https://pkgs.k8s.io/core:/stable:/$K8S_VERSION/deb/Release.key" | sudo gpg --dearmor -o "$KUBERNETES_APT_KEYRING" 2>/dev/null; then
        echo "deb [signed-by=$KUBERNETES_APT_KEYRING] https://pkgs.k8s.io/core:/stable:/$K8S_VERSION/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
        log_info "✓ Kubernetes repository configured successfully"
    else
        log_warning "Kubernetes key download/conversion failed (likely 403/404) - Kubernetes repo will not be used"
    fi

    # ===== CRI-O REPOSITORY SETUP =====
    log_info "Setting up CRI-O repository via curl + GPG key"

    CRIO_KEY_FILE='/tmp/crio.key'
    CRIO_APT_KEYRING='/usr/share/keyrings/cri-o-apt-keyring.gpg'
    
    # Clean up old keyring file
    sudo rm -f "$CRIO_APT_KEYRING"
    
    # Download and convert CRI-O GPG key in one pipeline (soft failure - continues if 404/403)
    log_info "Downloading and converting CRI-O GPG key from OpenSUSE"
    if sudo curl -fsSL $PROXY_FLAG "https://download.opensuse.org/repositories/isv:/cri-o:/stable:/$K8S_VERSION/deb/Release.key" | sudo gpg --dearmor -o "$CRIO_APT_KEYRING" 2>/dev/null; then
        echo "deb [signed-by=$CRIO_APT_KEYRING] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/$K8S_VERSION/deb/ /" | sudo tee /etc/apt/sources.list.d/cri-o.list > /dev/null
        log_info "✓ CRI-O repository configured successfully"
    else
        log_warning "CRI-O key download/conversion failed (likely 404/403) - CRI-O repo will not be used"
    fi

    # ===== UPDATE APT PACKAGE LIST =====
    log_info "Step 4: Final update of package list with new repositories"
    # Allow unsigned/unauthenticated repos in case GPG key downloads failed
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -o Acquire::AllowInsecureRepositories=true -o Acquire::AllowUnauthenticated=true -qq --yes --allow-releaseinfo-change 2>&1 | grep -v "^Reading" | grep -v "^Building" | grep -v "WARNING" || true

}

install_with_retry() {
    local package="$1"
    local retries="$2"
    local attempt=1
    
    while [ $attempt -le $retries ]; do
        log_info "Installing $package (attempt $attempt/$retries)"
        
        # Try to install - check exit status directly
        if sudo DEBIAN_FRONTEND=noninteractive apt-get install -qq --yes "$package" >/dev/null 2>&1; then
            log_info "✓ $package ready (installed or already present)"
            return 0
        fi
        
        # Installation failed
        log_warning "$package installation failed (attempt $attempt/$retries)"
        
        if [ $attempt -lt $retries ]; then
            log_info "Attempting repair: dpkg --configure -a && apt --fix-broken install"
            sudo dpkg --configure -a 2>/dev/null || true
            sudo apt --fix-broken install -y 2>/dev/null || true
            attempt=$((attempt + 1))
        else
            log_warning "$package installation failed after $retries retries - continuing with soft failure"
            return 1
        fi
    done
}

set_kubernetes_apt_repository "$K8S_VERSION" "$PROXY"

log_info "=== Downloading CRI-O ==="
download_packages 'cri-o'

log_info "=== Downloading Kubernetes Tools ==="
SHORT_K8S_VERSION="${K8S_VERSION#v}.0-1.1"  # v1.35 -> 1.35.0-1.1 (package version format)
log_info "Target Kubernetes version: $SHORT_K8S_VERSION"

download_packages "kubectl=$SHORT_K8S_VERSION"
download_packages "kubelet=$SHORT_K8S_VERSION"
download_packages "kubeadm=$SHORT_K8S_VERSION"

# Cleanup extra versions (keep only specified version)
log_info "Cleaning up extra package versions"
cd "$TARGET_PATH" && sudo find . -maxdepth 1 -type f \
    \( -name 'kubeadm_*.deb' -o -name 'kubectl_*.deb' -o -name 'kubelet_*.deb' \) \
    ! -name "*_${SHORT_K8S_VERSION}_amd64.deb" \
    -exec sudo rm -f {} + || true

log_info "Download verification:"
log_info "Total packages: $(ls "$TARGET_PATH"/*.deb 2>/dev/null | wc -l)"
ls -lh "$TARGET_PATH"/*.deb 2>/dev/null || true

   
