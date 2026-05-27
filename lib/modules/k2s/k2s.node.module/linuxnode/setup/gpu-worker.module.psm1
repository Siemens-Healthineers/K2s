# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
    Module for setting up GPU support on external Linux worker nodes.

.DESCRIPTION
    This module provides functions to configure external Linux workers as GPU-capable nodes.
    It handles:
    - NVIDIA driver verification
    - NVIDIA Container Toolkit installation
    - CRI-O/CDI configuration
    - Node labeling for GPU workloads

    Prerequisites:
    - NVIDIA kernel drivers must be pre-installed on the target Linux machine
    - The node must be accessible via SSH
#>

$infraModule = "$PSScriptRoot/../../../../k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../../k2s.cluster.module/k2s.cluster.module.psm1"

Import-Module $infraModule, $clusterModule

# GPU node label keys used by K2s
$script:GpuLabelKey = 'k2s.io/gpu-node'
$script:GpuLabel = 'gpu'
$script:AcceleratorLabel = 'accelerator'

<#
.SYNOPSIS
    Verifies that NVIDIA drivers are installed and functional on the target Linux node.

.DESCRIPTION
    Checks that nvidia-smi is available and returns valid output on the remote Linux machine.
    This is a prerequisite check before GPU setup can proceed.

.PARAMETER UserName
    SSH username for the remote node.

.PARAMETER IpAddress
    IP address of the remote node.

.OUTPUTS
    Returns $true if NVIDIA drivers are functional, $false otherwise.
    Throws an error with a clear message if drivers are not found.
#>
function Test-NvidiaDriverAvailable {
    param (
        [Parameter(Mandatory = $true)]
        [string] $UserName,
        [Parameter(Mandatory = $true)]
        [string] $IpAddress
    )

    Write-Log "[GPU] Verifying NVIDIA driver availability on node $IpAddress" -Console

    # Check if nvidia-smi exists and is executable
    $nvidiaSmiCheck = Invoke-CmdOnVmViaSSHKey -CmdToExecute 'which nvidia-smi 2>/dev/null || echo "NOT_FOUND"' -UserName $UserName -IpAddress $IpAddress -IgnoreErrors
    if ($nvidiaSmiCheck.Output -match 'NOT_FOUND' -or [string]::IsNullOrWhiteSpace($nvidiaSmiCheck.Output)) {
        $errMsg = @"
[GPU] NVIDIA driver not found on node $IpAddress.
The nvidia-smi command is not available, which indicates the NVIDIA kernel driver is not installed.

Prerequisites for GPU support:
1. Install NVIDIA drivers on the Linux machine:
   - For Debian/Ubuntu: https://wiki.debian.org/NvidiaGraphicsDrivers
   - Or use the official NVIDIA driver installer: https://www.nvidia.com/Download/index.aspx
2. Reboot the machine after driver installation
3. Verify with: nvidia-smi

After installing drivers, re-run the node add command with --enable-gpu.
"@
        throw $errMsg
    }

    # Verify nvidia-smi runs successfully and can query the GPU
    $nvidiaSmiResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute 'nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>&1' -UserName $UserName -IpAddress $IpAddress -IgnoreErrors
    if (!$nvidiaSmiResult.Success -or [string]::IsNullOrWhiteSpace($nvidiaSmiResult.Output)) {
        $errMsg = @"
[GPU] NVIDIA driver is installed but nvidia-smi failed on node $IpAddress.
This could indicate:
- Driver/kernel mismatch (try rebooting the machine)
- No NVIDIA GPU hardware detected
- Driver initialization failure

nvidia-smi output: $($nvidiaSmiResult.Output)

Please resolve the driver issue and try again.
"@
        throw $errMsg
    }

    Write-Log "[GPU] NVIDIA driver verified on $IpAddress: $($nvidiaSmiResult.Output)" -Console
    return $true
}

<#
.SYNOPSIS
    Installs and configures the NVIDIA Container Toolkit on the target Linux node.

.DESCRIPTION
    Installs the NVIDIA Container Toolkit packages required for running GPU workloads
    in containers. Supports both online (apt) and offline (pre-downloaded packages)
    installation modes.

.PARAMETER UserName
    SSH username for the remote node.

.PARAMETER IpAddress
    IP address of the remote node.

.PARAMETER Proxy
    Optional HTTP proxy for package downloads.

.PARAMETER Offline
    When set, uses pre-downloaded packages from the node package instead of apt.

.PARAMETER NodePackagePath
    Path to the node package directory containing offline GPU packages.
#>
function Install-NvidiaContainerToolkit {
    param (
        [Parameter(Mandatory = $true)]
        [string] $UserName,
        [Parameter(Mandatory = $true)]
        [string] $IpAddress,
        [Parameter(Mandatory = $false)]
        [string] $Proxy = '',
        [Parameter(Mandatory = $false)]
        [switch] $Offline = $false,
        [Parameter(Mandatory = $false)]
        [string] $NodePackagePath = ''
    )

    Write-Log "[GPU] Installing NVIDIA Container Toolkit on node $IpAddress" -Console

    $requiredPackages = @(
        'libnvidia-container1',
        'libnvidia-container-tools',
        'nvidia-container-runtime',
        'nvidia-container-toolkit'
    )

    # Check if already installed
    $alreadyInstalled = $true
    foreach ($pkg in $requiredPackages) {
        $checkResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute "dpkg -l $pkg 2>/dev/null | grep -q '^ii'" -UserName $UserName -IpAddress $IpAddress -IgnoreErrors
        if (!$checkResult.Success) {
            $alreadyInstalled = $false
            break
        }
    }

    if ($alreadyInstalled) {
        Write-Log "[GPU] NVIDIA Container Toolkit already installed on $IpAddress" -Console
        return
    }

    if ($Offline) {
        Install-NvidiaContainerToolkitOffline -UserName $UserName -IpAddress $IpAddress -NodePackagePath $NodePackagePath
    } else {
        Install-NvidiaContainerToolkitOnline -UserName $UserName -IpAddress $IpAddress -Proxy $Proxy
    }

    # Verify installation
    $verifyResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute 'dpkg -l nvidia-container-toolkit 2>/dev/null | grep -q "^ii"' -UserName $UserName -IpAddress $IpAddress -IgnoreErrors
    if (!$verifyResult.Success) {
        throw "[GPU] Failed to verify NVIDIA Container Toolkit installation on $IpAddress"
    }

    Write-Log "[GPU] NVIDIA Container Toolkit installed successfully on $IpAddress" -Console
}

<#
.SYNOPSIS
    Installs NVIDIA Container Toolkit packages from the internet.
#>
function Install-NvidiaContainerToolkitOnline {
    param (
        [Parameter(Mandatory = $true)]
        [string] $UserName,
        [Parameter(Mandatory = $true)]
        [string] $IpAddress,
        [Parameter(Mandatory = $false)]
        [string] $Proxy = ''
    )

    Write-Log "[GPU] Installing NVIDIA Container Toolkit (online) on $IpAddress" -Console

    $proxyEnv = ''
    $curlProxy = ''
    if (![string]::IsNullOrWhiteSpace($Proxy)) {
        $proxyEnv = "http_proxy=$Proxy https_proxy=$Proxy "
        $curlProxy = "-x $Proxy"
    }

    # Add NVIDIA Container Toolkit repository
    $repoSetupCmd = @"
curl --retry 3 --retry-all-errors -fsSL https://nvidia.github.io/libnvidia-container/gpgkey $curlProxy | sudo gpg --dearmor --batch --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg && \
curl --retry 3 --retry-all-errors -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list $curlProxy | \
sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
"@
    $repoResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute $repoSetupCmd -UserName $UserName -IpAddress $IpAddress
    if (!$repoResult.Success) {
        throw "[GPU] Failed to set up NVIDIA repository on $IpAddress. Ensure the node has internet access or use --node-package for offline installation."
    }

    # Update apt and install packages
    $updateCmd = "${proxyEnv}sudo apt-get update"
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute $updateCmd -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output | Write-Log

    $installCmd = "${proxyEnv}sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libnvidia-container1 libnvidia-container-tools nvidia-container-runtime nvidia-container-toolkit"
    $installResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute $installCmd -UserName $UserName -IpAddress $IpAddress
    $installResult.Output | Write-Log

    if (!$installResult.Success) {
        throw "[GPU] Failed to install NVIDIA Container Toolkit packages on $IpAddress"
    }
}

<#
.SYNOPSIS
    Installs NVIDIA Container Toolkit packages from pre-downloaded packages.
#>
function Install-NvidiaContainerToolkitOffline {
    param (
        [Parameter(Mandatory = $true)]
        [string] $UserName,
        [Parameter(Mandatory = $true)]
        [string] $IpAddress,
        [Parameter(Mandatory = $false)]
        [string] $NodePackagePath = ''
    )

    Write-Log "[GPU] Installing NVIDIA Container Toolkit (offline) on $IpAddress" -Console

    # Look for GPU packages in the node package directory
    $gpuPackagesDir = ''
    if (![string]::IsNullOrWhiteSpace($NodePackagePath)) {
        # Check for gpu-packages directory in the extracted node package
        # The node package structure is: packages/<os>/gpu-packages/
        $potentialPaths = @(
            (Join-Path $NodePackagePath 'packages' '*' 'gpu-packages'),  # packages/debian13/gpu-packages
            (Join-Path $NodePackagePath 'gpu-packages'),                  # gpu-packages (flat)
            (Join-Path $NodePackagePath 'packages' 'gpu'),                # packages/gpu
            (Join-Path $NodePackagePath 'nvidia-container-toolkit')       # nvidia-container-toolkit
        )
        foreach ($pathPattern in $potentialPaths) {
            $foundPaths = @(Get-ChildItem -Path $pathPattern -Directory -ErrorAction SilentlyContinue)
            if ($foundPaths.Count -gt 0) {
                $gpuPackagesDir = $foundPaths[0].FullName
                break
            }
            # Also check if the path itself exists (for non-wildcard paths)
            if (Test-Path $pathPattern -PathType Container) {
                $gpuPackagesDir = $pathPattern
                break
            }
        }
    }

    # Also check linuxnode artifacts directory
    if ([string]::IsNullOrWhiteSpace($gpuPackagesDir)) {
        $linuxNodeDir = Get-DirectoryOfLinuxNodeArtifactsOnWindowsHost
        $linuxNodeGpuPath = Join-Path $linuxNodeDir 'gpu-packages'
        if (Test-Path $linuxNodeGpuPath) {
            $gpuPackagesDir = $linuxNodeGpuPath
        }
    }

    if ([string]::IsNullOrWhiteSpace($gpuPackagesDir) -or !(Test-Path $gpuPackagesDir)) {
        throw @"
[GPU] Offline GPU packages not found.
To enable GPU support offline, create a node package that includes GPU artifacts:
  k2s system package --node-package --os debian13 --include-gpu --target-dir C:\output --name debian13-node-gpu.zip

Then use:
  k2s node add --ip-addr <ip> --username <user> --enable-gpu --node-package <path-to-package>
"@
    }

    Write-Log "[GPU] Found GPU packages at: $gpuPackagesDir" -Console

    # Copy GPU packages to remote node
    $remoteGpuDir = '/tmp/k2s-gpu-packages'
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute "rm -rf $remoteGpuDir && mkdir -p $remoteGpuDir" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
    
    # Copy all .deb files
    Copy-ToRemoteComputerViaSSHKey -Source "$gpuPackagesDir\*.deb" -Target $remoteGpuDir -UserName $UserName -IpAddress $IpAddress

    # Install packages
    $installCmd = "cd $remoteGpuDir && sudo dpkg -i *.deb 2>&1"
    $installResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute $installCmd -UserName $UserName -IpAddress $IpAddress
    $installResult.Output | Write-Log

    # Clean up
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute "rm -rf $remoteGpuDir" -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output | Write-Log

    if (!$installResult.Success) {
        # Try to fix broken dependencies and reinstall
        Write-Log "[GPU] Initial install had issues, attempting to fix dependencies..." -Console
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo apt-get --fix-broken install -y' -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output | Write-Log
    }
}

<#
.SYNOPSIS
    Configures CRI-O for NVIDIA GPU support via CDI.

.DESCRIPTION
    Configures CRI-O to use NVIDIA Container Runtime and CDI for GPU device injection.
    This is required for Kubernetes to schedule GPU workloads on the node.

.PARAMETER UserName
    SSH username for the remote node.

.PARAMETER IpAddress
    IP address of the remote node.
#>
function Set-CrioGpuConfiguration {
    param (
        [Parameter(Mandatory = $true)]
        [string] $UserName,
        [Parameter(Mandatory = $true)]
        [string] $IpAddress
    )

    Write-Log "[GPU] Configuring CRI-O for GPU support on $IpAddress" -Console

    # Generate CDI spec for NVIDIA devices
    Write-Log "[GPU] Generating CDI specification..." -Console
    $cdiCmd = 'sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml 2>&1 || true'
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute $cdiCmd -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output | Write-Log

    # Ensure CDI directory exists and spec is readable
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo mkdir -p /etc/cdi && sudo chmod 755 /etc/cdi' -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output | Write-Log

    # Configure CRI-O to enable CDI devices
    $crioConfigCmd = @'
sudo mkdir -p /etc/crio/crio.conf.d
cat <<'EOF' | sudo tee /etc/crio/crio.conf.d/99-nvidia-gpu.conf
[crio.runtime]
# Enable CDI for device injection
enable_cdi = true
cdi_spec_dirs = ["/etc/cdi", "/var/run/cdi"]
EOF
'@
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute $crioConfigCmd -UserName $UserName -IpAddress $IpAddress).Output | Write-Log

    # Restart CRI-O to apply changes
    Write-Log "[GPU] Restarting CRI-O to apply GPU configuration..." -Console
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo systemctl restart crio' -UserName $UserName -IpAddress $IpAddress).Output | Write-Log

    # Wait for CRI-O to be ready
    Start-Sleep -Seconds 3
    $crioStatus = Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo systemctl is-active crio' -UserName $UserName -IpAddress $IpAddress -IgnoreErrors
    if ($crioStatus.Output -notmatch 'active') {
        Write-Log "[GPU] WARNING: CRI-O may not have restarted correctly. Status: $($crioStatus.Output)" -Console
    }

    Write-Log "[GPU] CRI-O GPU configuration complete on $IpAddress" -Console
}

<#
.SYNOPSIS
    Labels a Kubernetes node as GPU-capable.

.DESCRIPTION
    Applies GPU labels to the node so it can be targeted by GPU workloads
    and the NVIDIA device plugin DaemonSet.

.PARAMETER NodeName
    Kubernetes node name (lowercase hostname).
#>
function Set-GpuNodeLabels {
    param (
        [Parameter(Mandatory = $true)]
        [string] $NodeName
    )

    Write-Log "[GPU] Labeling node '$NodeName' as GPU-capable" -Console

    $kubeToolsPath = Get-KubeToolsPath
    $kubectl = "$kubeToolsPath\kubectl.exe"

    # Apply GPU labels
    $labels = @(
        "$script:GpuLabelKey=true",
        "$script:GpuLabel=true",
        "$script:AcceleratorLabel=nvidia"
    )

    foreach ($label in $labels) {
        $result = & $kubectl label node $NodeName.ToLower() $label --overwrite 2>&1
        Write-Log "[GPU] Applied label '$label': $result"
    }

    Write-Log "[GPU] Node '$NodeName' labeled as GPU-capable" -Console
}

<#
.SYNOPSIS
    Main entry point for setting up GPU support on an external Linux worker node.

.DESCRIPTION
    Orchestrates the complete GPU setup process:
    1. Verifies NVIDIA driver availability
    2. Installs NVIDIA Container Toolkit
    3. Configures CRI-O for GPU support
    4. Labels the node for GPU workloads

.PARAMETER UserName
    SSH username for the remote node.

.PARAMETER IpAddress
    IP address of the remote node.

.PARAMETER NodeName
    Kubernetes node name (hostname).

.PARAMETER Proxy
    Optional HTTP proxy for package downloads.

.PARAMETER NodePackagePath
    Path to node package for offline installation.
#>
function Initialize-GpuWorkerNode {
    param (
        [Parameter(Mandatory = $true)]
        [string] $UserName,
        [Parameter(Mandatory = $true)]
        [string] $IpAddress,
        [Parameter(Mandatory = $true)]
        [string] $NodeName,
        [Parameter(Mandatory = $false)]
        [string] $Proxy = '',
        [Parameter(Mandatory = $false)]
        [string] $NodePackagePath = ''
    )

    Write-Log '[GPU] ======================================' -Console
    Write-Log "[GPU] Initializing GPU support for worker node $NodeName ($IpAddress)" -Console
    Write-Log '[GPU] ======================================' -Console

    # Step 1: Verify NVIDIA driver
    Test-NvidiaDriverAvailable -UserName $UserName -IpAddress $IpAddress

    # Step 2: Install NVIDIA Container Toolkit
    $offline = ![string]::IsNullOrWhiteSpace($NodePackagePath)
    Install-NvidiaContainerToolkit -UserName $UserName -IpAddress $IpAddress -Proxy $Proxy -Offline:$offline -NodePackagePath $NodePackagePath

    # Step 3: Configure CRI-O
    Set-CrioGpuConfiguration -UserName $UserName -IpAddress $IpAddress

    # Step 4: Label the node
    Set-GpuNodeLabels -NodeName $NodeName

    Write-Log '[GPU] ======================================' -Console
    Write-Log "[GPU] GPU support initialized for node $NodeName" -Console
    Write-Log '[GPU] ======================================' -Console
    Write-Log '[GPU] The node is now ready for GPU workloads.' -Console
    Write-Log '[GPU] To run GPU pods, ensure the gpu-node addon is enabled:' -Console
    Write-Log '[GPU]   k2s addons enable gpu-node' -Console
    Write-Log '[GPU] ======================================' -Console
}

<#
.SYNOPSIS
    Removes GPU configuration from a Linux worker node.

.DESCRIPTION
    Cleans up GPU labels and optionally removes NVIDIA Container Toolkit.

.PARAMETER NodeName
    Kubernetes node name.

.PARAMETER UserName
    SSH username for the remote node.

.PARAMETER IpAddress
    IP address of the remote node.

.PARAMETER RemovePackages
    When set, also removes NVIDIA Container Toolkit packages.
#>
function Remove-GpuWorkerNodeConfiguration {
    param (
        [Parameter(Mandatory = $true)]
        [string] $NodeName,
        [Parameter(Mandatory = $false)]
        [string] $UserName = '',
        [Parameter(Mandatory = $false)]
        [string] $IpAddress = '',
        [Parameter(Mandatory = $false)]
        [switch] $RemovePackages = $false
    )

    Write-Log "[GPU] Removing GPU configuration from node '$NodeName'" -Console

    $kubeToolsPath = Get-KubeToolsPath
    $kubectl = "$kubeToolsPath\kubectl.exe"

    # Remove GPU labels
    $labels = @(
        "$script:GpuLabelKey-",
        "$script:GpuLabel-",
        "$script:AcceleratorLabel-"
    )

    foreach ($label in $labels) {
        $result = & $kubectl label node $NodeName.ToLower() $label 2>&1
        Write-Log "[GPU] Removed label: $result"
    }

    # Optionally remove packages
    if ($RemovePackages -and ![string]::IsNullOrWhiteSpace($UserName) -and ![string]::IsNullOrWhiteSpace($IpAddress)) {
        Write-Log "[GPU] Removing NVIDIA Container Toolkit packages from $IpAddress" -Console
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo apt-get remove -y nvidia-container-toolkit libnvidia-container1 libnvidia-container-tools nvidia-container-runtime 2>/dev/null || true' -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output | Write-Log
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo rm -f /etc/crio/crio.conf.d/99-nvidia-gpu.conf' -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output | Write-Log
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo systemctl restart crio' -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output | Write-Log
    }

    Write-Log "[GPU] GPU configuration removed from node '$NodeName'" -Console
}

# Export module functions
Export-ModuleMember -Function Test-NvidiaDriverAvailable,
    Install-NvidiaContainerToolkit,
    Set-CrioGpuConfiguration,
    Set-GpuNodeLabels,
    Initialize-GpuWorkerNode,
    Remove-GpuWorkerNodeConfiguration
