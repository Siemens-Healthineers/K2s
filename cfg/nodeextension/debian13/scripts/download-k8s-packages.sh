#!/bin/bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT
#
# Debian 13 (Trixie) variant

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

refresh_apt_cache() {
    local max_retries=2
    local attempt=1

    while [ $attempt -le $max_retries ]; do
        if sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq --yes --allow-releaseinfo-change; then
            return 0
        fi

        log_warning "apt-get update failed (attempt $attempt/$max_retries)"
        if [ $attempt -lt $max_retries ]; then
            log_info "Repairing apt/dpkg state before retry"
            sudo dpkg --configure -a >/dev/null 2>&1 || true
            sudo apt --fix-broken install -y >/dev/null 2>&1 || true
        fi
        attempt=$((attempt + 1))
    done

    log_warning "apt-get update failed after $max_retries attempts"
    return 1
}

# Normalize K8S_VERSION to vX.Y for repo URLs (repos use minor version only)
# e.g. v1.35.0 -> v1.35, v1.35 -> v1.35
K8S_VERSION_REPO=$(echo "$K8S_VERSION" | sed 's/^\(v[0-9]*\.[0-9]*\).*/\1/')
if [ -z "$K8S_VERSION_REPO" ]; then
    K8S_VERSION_REPO="$K8S_VERSION"
fi

# Main execution
log_info "Starting Kubernetes package download"
log_info "Target path: $TARGET_PATH"
log_info "K8s version: $K8S_VERSION (repo version: $K8S_VERSION_REPO)"

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
    local pkg_base="${package_name%%=*}"
    local pkg_version=""
    local max_retries=2
    local attempt=1
    local downloaded_main_package=0

    log_info "Downloading: $package_name"

    # Step 1: Download the main .deb (matches original PowerShell Command 1)
    while [ $attempt -le $max_retries ]; do
        local download_error_file
        download_error_file=$(mktemp)

        if cd "$TARGET_PATH" && sudo apt-get download --allow-unauthenticated "$package_name" 2>"$download_error_file"; then
            downloaded_main_package=1
            rm -f "$download_error_file"
            break
        fi

        local download_error
        download_error=$(tr '\n' ' ' < "$download_error_file" | sed 's/[[:space:]]\+/ /g' | sed 's/^ //;s/ $//')
        rm -f "$download_error_file"

        log_warning "Download failed for '$package_name' (attempt $attempt/$max_retries)"
        if [ -n "$download_error" ]; then
            log_warning "apt-get download error: $download_error"
        fi

        if [ $attempt -lt $max_retries ]; then
            log_info "Running repair before retry: dpkg --configure -a && apt --fix-broken install && apt-get update"
            sudo dpkg --configure -a >/dev/null 2>&1 || true
            sudo apt --fix-broken install -y >/dev/null 2>&1 || true
            sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq --yes --allow-releaseinfo-change >/dev/null 2>&1 || true
        fi

        attempt=$((attempt + 1))
    done

    if [[ "$package_name" == *"="* ]]; then
        pkg_version="${package_name#*=}"
    fi

    local deb_pattern="${pkg_base}*.deb"
    if [ -n "$pkg_version" ]; then
        deb_pattern="${pkg_base}_${pkg_version}_*.deb"
    fi

    if ls "$TARGET_PATH"/${deb_pattern} >/dev/null 2>&1; then
        cd "$TARGET_PATH" && sudo DEBIAN_FRONTEND=noninteractive \
            apt-get --reinstall install -y \
            --no-install-recommends --no-install-suggests \
            --simulate ./${deb_pattern} 2>/dev/null \
            | grep 'Inst ' \
            | cut -d ' ' -f 2 \
            | sort -u \
            | grep -v "^${pkg_base}$" \
            | xargs -r sudo apt-get download --allow-unauthenticated 2>/dev/null || true

        return 0
    fi

    if [ "$downloaded_main_package" -eq 1 ]; then
        return 0
    fi

    log_warning "Package was not downloaded: $package_name"
    return 1
}

log_info "=== Downloading Base Tools ==="
log_info "Refreshing apt package cache before base tools download"
refresh_apt_cache || true

if ! download_packages 'gpg' || ! ls "$TARGET_PATH"/gpg*.deb >/dev/null 2>&1; then
    log_warning "gpg download failed; cannot continue"
    exit 1
fi
# apt-transport-https was removed from Debian 13 (Trixie): HTTPS support is
# built into apt natively and the package no longer exists in the archive.
download_packages 'ca-certificates'

set_kubernetes_apt_repository() {
    local K8S_VERSION="$1"
    local PROXY="${2:-}"
    local MAX_RETRIES=2

    log_info "Setting up repositories for K8s version: $K8S_VERSION"

    # Remove stale .list files from previous runs to avoid stale URL conflicts
    sudo rm -f /etc/apt/sources.list.d/kubernetes.list /etc/apt/sources.list.d/cri-o.list

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
    if sudo curl -fsSL $PROXY_FLAG "https://pkgs.k8s.io/core:/stable:/$K8S_VERSION_REPO/deb/Release.key" | sudo gpg --dearmor -o "$KUBERNETES_APT_KEYRING" 2>/dev/null; then
        echo "deb [signed-by=$KUBERNETES_APT_KEYRING] https://pkgs.k8s.io/core:/stable:/$K8S_VERSION_REPO/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
        log_info "✓ Kubernetes repository configured successfully"
    else
        log_warning "Kubernetes key download/conversion failed (likely 403/404) - configuring repo as trusted (no GPG verification)"
        echo "deb [trusted=yes] https://pkgs.k8s.io/core:/stable:/$K8S_VERSION_REPO/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
    fi

    # ===== CRI-O REPOSITORY SETUP =====
    log_info "Setting up CRI-O repository via curl + GPG key"

    CRIO_KEY_FILE='/tmp/crio.key'
    CRIO_APT_KEYRING='/usr/share/keyrings/cri-o-apt-keyring.gpg'
    
    # Clean up old keyring file
    sudo rm -f "$CRIO_APT_KEYRING"
    
    # Download and convert CRI-O GPG key in one pipeline (soft failure - continues if 404/403)
    log_info "Downloading and converting CRI-O GPG key from OpenSUSE"
    if sudo curl -fsSL $PROXY_FLAG "https://download.opensuse.org/repositories/isv:/cri-o:/stable:/$K8S_VERSION_REPO/deb/Release.key" | sudo gpg --dearmor -o "$CRIO_APT_KEYRING" 2>/dev/null; then
        echo "deb [signed-by=$CRIO_APT_KEYRING] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/$K8S_VERSION_REPO/deb/ /" | sudo tee /etc/apt/sources.list.d/cri-o.list > /dev/null
        log_info "✓ CRI-O repository configured successfully"
    else
        log_warning "CRI-O key download/conversion failed (likely 404/403) - configuring repo as trusted (no GPG verification)"
        echo "deb [trusted=yes] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/$K8S_VERSION_REPO/deb/ /" | sudo tee /etc/apt/sources.list.d/cri-o.list > /dev/null
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

set_kubernetes_apt_repository "$K8S_VERSION_REPO" "$PROXY"

log_info "=== Downloading CRI-O ==="
download_packages 'cri-o'

log_info "=== Downloading Kubernetes Tools ==="
SHORT_K8S_VERSION="${K8S_VERSION#v}-1.1"
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

   
