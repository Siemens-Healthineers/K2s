# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
    Downloads all Kubernetes node packages (kubelet, kubeadm, kubectl, CRI-O, buildah)
    and their dependencies for the specified Linux distribution, then bundles them into a zip file
    for offline installation.

.DESCRIPTION
    Boots an ephemeral Hyper-V VM from a cloud image matching the target OS/version,
    SSHes in, runs the distribution-specific download scripts to fetch .deb packages via
    apt-get download, copies the packages back to the Windows host, and creates a zip archive.

    The -TargetDirectory and -ZipPackageFileName flags are required and control
    where the resulting zip is written and what it is named.

.PARAMETER OS
    Linux distribution name and version combined. Supported: debian12, debian13. Example: debian12

.PARAMETER TargetDirectory
    Directory where the resulting zip file is written.

.PARAMETER ZipPackageFileName
    File name for the resulting zip archive (must end in .zip).

.PARAMETER Proxy
    Optional HTTP proxy to use for package downloads inside the VM (e.g. http://10.0.0.1:8080).

.PARAMETER ShowLogs
    When set, all log output is also printed to the console.

.EXAMPLE
    # Download Debian 12 node packages
    k2s system package --node-package --os debian12 --target-dir C:\output --name mynode.zip

.EXAMPLE
    # Download Debian 13 node packages through a proxy
    k2s system package --node-package --os debian13 --target-dir C:\output --name mynode.zip --proxy http://proxy:8080
#>

param (
    [Parameter(Mandatory = $true, HelpMessage = 'Target Linux distribution and version combined (e.g. debian12, debian13)')]
    [string] $OS,

    [Parameter(Mandatory = $true, HelpMessage = 'Directory where the resulting zip file is written')]
    [string] $TargetDirectory,

    [Parameter(Mandatory = $true, HelpMessage = 'File name of the resulting zip archive (must end in .zip)')]
    [string] $ZipPackageFileName,

    [Parameter(Mandatory = $false, HelpMessage = 'HTTP proxy for package downloads inside the VM')]
    [string] $Proxy = '',

    [Parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,

    [Parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,

    [Parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$infraModule = "$PSScriptRoot/../../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule  = "$PSScriptRoot/../../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"
$vmProvisioningHelper = "$PSScriptRoot\New-K2sNodePackage.VmProvisioning.ps1"
$puttyToolsHelper = "$PSScriptRoot\New-K2sPackage.PuttyTools.ps1"

Import-Module $infraModule, $nodeModule
. $vmProvisioningHelper
. $puttyToolsHelper

if ($EncodeStructuredOutput) {
    Initialize-Logging -ShowLogs:$false
} else {
    Initialize-Logging -ShowLogs:$ShowLogs
}

$distributionKey = $OS.ToLower()

Write-Log "[NodePkg] Starting node package creation for OS='$OS'" -Console
Write-Log "[NodePkg] Distribution key: $distributionKey" -Console
Write-Log "[NodePkg] Target directory: $TargetDirectory" -Console
Write-Log "[NodePkg] Output zip: $ZipPackageFileName" -Console

# Clean up stale node-package NATs and switches from previous failed runs.
# Without this, random subnet selection can collide with a stale NAT/route,
# causing New-NetIPAddress to silently fail so the host cannot reach the VM (SSH timeout).
$staleNetworkNamePattern = 'k2s-nodepkg-debian*'
Write-Log "[NodePkg] Cleaning up stale NATs and switches matching '$staleNetworkNamePattern' from previous runs..." -Console
Get-NetNat | Where-Object Name -like $staleNetworkNamePattern | ForEach-Object {
    Write-Log "[NodePkg] Removing stale NAT: $($_.Name) ($($_.InternalIPInterfaceAddressPrefix))" -Console
    Remove-NetNat -Name $_.Name -Confirm:$false -ErrorAction SilentlyContinue
}
Get-VMSwitch | Where-Object Name -like $staleNetworkNamePattern | ForEach-Object {
    Write-Log "[NodePkg] Removing stale vSwitch: $($_.Name)" -Console
    Remove-VMSwitch -Name $_.Name -Force -ErrorAction SilentlyContinue
}

# Initialize variables for VM and network provisioning
$tempPath = [System.IO.Path]::GetTempPath()
$stagingDir = Join-Path $tempPath "k2s-node-pkg-$([guid]::NewGuid().ToString().Substring(0, 8))"
$vmName = "k2s-nodepkg-$distributionKey-$(Get-Random -Maximum 9999)"
$switchName = ''
$natName = ''
$guestIp = ''
$sshUser = ''
$sshPwd = ''
$inProvisioningVhdxPath = ''

$provisioningDir = Join-Path $stagingDir "provisioning"
$downloadsDir = Join-Path $stagingDir "downloads"
$packagesDir = Join-Path $stagingDir "packages"
$packagesByOsDir = Join-Path $packagesDir $distributionKey
$k8sPkgDir = Join-Path $packagesByOsDir "kubernetes"
$buildahPkgDir = Join-Path $packagesByOsDir "buildah"
$imagesDir = Join-Path $stagingDir "images"
$remoteK8sPkgDir = "/tmp/k2s-k8s-packages"
$remoteBuildahPkgDir = "/tmp/k2s-buildah-packages"
$remoteImagesExportDir = "/tmp/k2s-images"
$vmProvisioningStarted = $false

New-Item -Path $stagingDir -ItemType Directory -Force | Out-Null
New-Item -Path $packagesDir -ItemType Directory -Force | Out-Null
New-Item -Path $packagesByOsDir -ItemType Directory -Force | Out-Null
New-Item -Path $k8sPkgDir -ItemType Directory -Force | Out-Null
New-Item -Path $buildahPkgDir -ItemType Directory -Force | Out-Null

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------

Test-SupportedWorkerOS -OS $distributionKey

$zipTarget = Join-Path $TargetDirectory $ZipPackageFileName
if (Test-Path $zipTarget) {
    Write-Log "[NodePkg] Package already exists: $zipTarget" -Console
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null}
    }
    return
}

# ---------------------------------------------------------------------------
# Prerequisite: ensure plink.exe and pscp.exe are available
# ---------------------------------------------------------------------------
Assert-PuttyToolsReady -LogPrefix '[NodePkg]' -Proxy $Proxy

# ---------------------------------------------------------------------------
# Resolve paths and versions
# ---------------------------------------------------------------------------
$k8sVersion  = Get-DefaultK8sVersion

function Assert-PackagesDownloaded {
    param(
        [Parameter(Mandatory = $true)]
        [string]$K8sPath,
        [Parameter(Mandatory = $true)]
        [string]$BuildahPath
    )

    $k8sDebCount = @(Get-ChildItem -Path $K8sPath -Filter '*.deb' -File -ErrorAction SilentlyContinue).Count
    $buildahDebCount = @(Get-ChildItem -Path $BuildahPath -Filter '*.deb' -File -ErrorAction SilentlyContinue).Count
    $totalDebCount = $k8sDebCount + $buildahDebCount

    Write-Log "[NodePkg] Local package counts: kubernetes=$k8sDebCount, buildah=$buildahDebCount, total=$totalDebCount" -Console

    if ($totalDebCount -eq 0) {
        throw "[NodePkg] No .deb packages were copied from the VM. Check remote download script output and remote package paths."
    }
}

try {

	$setupType = Get-ConfigSetupType
    if ($setupType -eq 'k2s') {
        # Get the installed OS distro key from the kubemaster VM (e.g. 'debian12', 'debian13')
        $controlPlaneUserName = Get-DefaultUserNameControlPlane
        $controlPlaneIpAddress = Get-ConfiguredIPControlPlane
        $installedDistro = Get-InstalledDistribution -UserName $controlPlaneUserName -IpAddress $controlPlaneIpAddress
        # $installedDistro is e.g. 'debian12'
        if ($installedDistro -eq $distributionKey) {
            Write-Log "[NodePkg] Detected that control plane VM is already running '$distributionKey'. Copying packages from kubemaster..." -Console

            # Remove the empty staging dirs so Copy-DebPackagesFromControlPlaneToWindowsHost can populate them
            Remove-Item $packagesByOsDir -Recurse -Force -ErrorAction SilentlyContinue

            # Copy kubernetes and buildah deb packages from kubemaster to the local staging dir
            Copy-DebPackagesFromControlPlaneToWindowsHost -TargetPath $packagesByOsDir

            # Copy container images from kubemaster to the local staging dir
            if (Test-Path -Path $imagesDir) {
                Remove-Item -Path $imagesDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            Copy-KubernetesImagesFromControlPlaneNodeToWindowsHost -TargetPath $imagesDir

            # Create zip at the requested output location
            New-Item -Path $TargetDirectory -ItemType Directory -Force | Out-Null
            Compress-Archive -Path @($packagesDir, $imagesDir) -DestinationPath $zipTarget -Force
            Write-Log "[NodePkg] Node package zip created from kubemaster: $zipTarget" -Console
            Write-Log "[NodePkg] Package creation for '$distributionKey' completed successfully (fast path via kubemaster)." -Console

            if ($EncodeStructuredOutput -eq $true) {
                Send-ToCli -MessageType $MessageType -Message @{Error = $null}
            }
            return
        } else {
            Write-Log "[NodePkg] Control plane VM is running '$installedDistro', which does not match the target distribution '$distributionKey'. Will proceed with provisioning a new VM for package creation." -Console
        }
    }

    $vmContext = Start-NodePackageVmProvisioning `
        -DistributionKey $distributionKey `
        -VmName $vmName `
        -Proxy $Proxy `
        -ShowLogs:$ShowLogs

    $switchName = $vmContext.SwitchName
    $natName = $vmContext.NatName
    $guestIp = $vmContext.GuestIp
    $sshUser = $vmContext.SshUser
    $sshPwd = $vmContext.SshPwd
    $inProvisioningVhdxPath = $vmContext.InProvisioningVhdxPath
    $vmProvisioningStarted = $true

    # -----------------------------------------------------------------------
    # Phase 4 - Download Kubernetes packages inside the VM
    # -----------------------------------------------------------------------
    Write-Log "[NodePkg] === Phase 4: Downloading Kubernetes packages inside VM (k8sVersion=$k8sVersion) ===" -Console
    Get-KubernetesArtifactsFromInternet `
        -UserName              $sshUser `
        -UserPwd               $sshPwd `
        -IpAddress             $guestIp `
        -Proxy                 $Proxy `
        -K8sVersion            $k8sVersion `
        -TargetPath            $remoteK8sPkgDir `
        -InstalledDistribution $distributionKey

    # -----------------------------------------------------------------------
    # Phase 5 - Download buildah packages inside the VM
    # -----------------------------------------------------------------------
    Write-Log "[NodePkg] === Phase 5: Downloading buildah packages inside VM ===" -Console
    Get-BuildahDebPackagesFromInternet `
        -UserName              $sshUser `
        -UserPwd               $sshPwd `
        -IpAddress             $guestIp `
        -TargetPath            $remoteBuildahPkgDir `
        -InstalledDistribution $distributionKey

    # -----------------------------------------------------------------------
    # Phase 6 - Install Kubernetes packages inside the VM
    # -----------------------------------------------------------------------
    Write-Log "[NodePkg] === Phase 6: Installing Kubernetes packages inside VM ===" -Console
    Install-KubernetesArtifacts `
        -UserName              $sshUser `
        -UserPwd               $sshPwd `
        -IpAddress             $guestIp `
        -Proxy                 $Proxy `
        -SourcePath            $remoteK8sPkgDir `
        -InstalledDistribution $distributionKey

    # -----------------------------------------------------------------------
    # Phase 7 - Install buildah packages inside the VM
    # -----------------------------------------------------------------------
    Write-Log "[NodePkg] === Phase 7: Installing buildah packages inside VM ===" -Console
    Install-BuildahDebPackages `
        -UserName              $sshUser `
        -UserPwd               $sshPwd `
        -IpAddress             $guestIp `
        -SourcePath            $remoteBuildahPkgDir `
        -InstalledDistribution $distributionKey

    # -----------------------------------------------------------------------
    # Phase 8 - Pull and export Kubernetes/flannel images from VM
    # -----------------------------------------------------------------------
    Write-Log "[NodePkg] === Phase 8: Pulling and exporting container images inside VM ===" -Console

    $remoteUser = "$sshUser@$guestIp"
    New-Item -Path $imagesDir -ItemType Directory -Force | Out-Null

    # Use existing image pull helpers from k2s.node.module
    Get-KubernetesImages `
        -UserName   $sshUser `
        -UserPwd    $sshPwd `
        -IpAddress  $guestIp `
        -K8sVersion $k8sVersion

    Get-FlannelImages `
        -UserName  $sshUser `
        -UserPwd   $sshPwd `
        -IpAddress $guestIp

    (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "mkdir -p $remoteImagesExportDir" -RemoteUser $remoteUser -RemoteUserPwd $sshPwd -IgnoreErrors).Output | Write-Log

    # Build export list from crictl JSON to avoid fragile text parsing.
    $imagesJsonOutput = (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute 'sudo crictl images -o json' -RemoteUser $remoteUser -RemoteUserPwd $sshPwd -IgnoreErrors).Output
    $imagesJsonText = ($imagesJsonOutput -join "`n")
    $imagesDoc = $imagesJsonText | ConvertFrom-Json

    $imageRefsToExport = @()
    foreach ($img in @($imagesDoc.images)) {
        foreach ($repoTag in @($img.repoTags)) {
            if ([string]::IsNullOrWhiteSpace($repoTag) -or $repoTag -match '<none>') {
                continue
            }
            if ($repoTag -like 'registry.k8s.io/*' -or $repoTag -like 'docker.io/flannel/*') {
                $imageRefsToExport += $repoTag
            }
        }
    }
    $imageRefsToExport = $imageRefsToExport | Select-Object -Unique

    if (@($imageRefsToExport).Count -eq 0) {
        throw "[NodePkg] No image matching 'registry.k8s.io/* or docker.io/flannel/*' found in crictl output."
    }

    Write-Log "[NodePkg] Images selected for export: $($imageRefsToExport -join ', ')" -Console

    foreach ($imageFullName in $imageRefsToExport) {
        $sanitizedName = $imageFullName.Replace('/','_').Replace(':', '__')
        $finalExportPath = Join-Path $imagesDir "$sanitizedName.tar"
        $targetFilePath = "$remoteImagesExportDir/${sanitizedName}.tar"
        $buildahPushCmd = 'sudo buildah push {0} oci-archive:{1}:{0} 2>&1' -f $imageFullName, $targetFilePath

        (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $buildahPushCmd -RemoteUser $remoteUser -RemoteUserPwd $sshPwd -IgnoreErrors).Output | Write-Log

        Copy-FromRemoteComputerViaUserAndPwd `
            -Source    $targetFilePath `
            -Target    $finalExportPath `
            -IpAddress $guestIp `
            -UserName  $sshUser `
            -UserPwd   $sshPwd

        (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "sudo rm -f $targetFilePath" -RemoteUser $remoteUser -RemoteUserPwd $sshPwd -IgnoreErrors).Output | Write-Log
    }

    $localExportCount = @(Get-ChildItem -Path $imagesDir -Filter '*.tar' -File -ErrorAction SilentlyContinue).Count
    if ($localExportCount -eq 0) {
        throw '[NodePkg] No container images were exported and copied to staging. Check image listing command output in logs.'
    }
    Write-Log "[NodePkg] Exported container images copied to staging: $localExportCount" -Console

    $remoteK8sDebCount = (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "ls -1 $remoteK8sPkgDir/*.deb 2>/dev/null | wc -l" -RemoteUser $remoteUser -RemoteUserPwd $sshPwd -IgnoreErrors).Output
    $remoteBuildahDebCount = (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "ls -1 $remoteBuildahPkgDir/*.deb 2>/dev/null | wc -l" -RemoteUser $remoteUser -RemoteUserPwd $sshPwd -IgnoreErrors).Output
    Write-Log "[NodePkg] Remote package counts before copy: kubernetes=$($remoteK8sDebCount.Trim()), buildah=$($remoteBuildahDebCount.Trim())" -Console

    # -----------------------------------------------------------------------
    # Phase 9 - Copy packages from VM back to Windows host
    # -----------------------------------------------------------------------
    Write-Log "[NodePkg] === Phase 9: Copying packages from VM to Windows ===" -Console
    Copy-FromRemoteComputerViaUserAndPwd `
        -Source    "$remoteK8sPkgDir/*" `
        -Target    $k8sPkgDir `
        -IpAddress $guestIp `
        -UserName  $sshUser `
        -UserPwd   $sshPwd

    Copy-FromRemoteComputerViaUserAndPwd `
        -Source    "$remoteBuildahPkgDir/*" `
        -Target    $buildahPkgDir `
        -IpAddress $guestIp `
        -UserName  $sshUser `
        -UserPwd   $sshPwd

    Assert-PackagesDownloaded -K8sPath $k8sPkgDir -BuildahPath $buildahPkgDir

    # -----------------------------------------------------------------------
    # Phase 10 - Create output zip
    # -----------------------------------------------------------------------
    Write-Log "[NodePkg] === Phase 10: Creating output zip ===" -Console
    New-Item -Path $TargetDirectory -ItemType Directory -Force | Out-Null
    $zipTarget = Join-Path $TargetDirectory $ZipPackageFileName
    if (Test-Path $zipTarget) { Remove-Item $zipTarget -Force }
    Compress-Archive -Path @($packagesDir, $imagesDir) -DestinationPath $zipTarget -Force
    Write-Log "[NodePkg] Node package zip created: $zipTarget" -Console
    Write-Log "[NodePkg] Package creation for '$distributionKey' completed successfully." -Console
}
catch {
    $errMsg = $_.Exception.Message
    Write-Log "[NodePkg] ERROR: $errMsg" -Console
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Error -Code 'node-package-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err}
        exit 0
    }
    throw
}
finally {

    if($vmProvisioningStarted)
    {
        Write-Log '[NodePkg] Cleaning up VM and network...' -Console

        $vmExists = $null -ne (Get-VM -Name $vmName -ErrorAction SilentlyContinue)
        if ($vmExists) {
            try { Stop-VirtualMachineForBaseImageProvisioning -Name $vmName }
            catch { Write-Log "[NodePkg] Warning during VM stop: $($_.Exception.Message)" -Console }

            try { Remove-VirtualMachineForBaseImageProvisioning -VmName $vmName -VhdxFilePath $inProvisioningVhdxPath }
            catch { Write-Log "[NodePkg] Warning during VM removal: $($_.Exception.Message)" -Console }
        }
        else {
            Write-Log "[NodePkg] No VM '$vmName' found for cleanup." -Console
        }

        try { Remove-NetworkForProvisioning -SwitchName $switchName -NatName $natName }
        catch { Write-Log "[NodePkg] Warning during network cleanup: $($_.Exception.Message)" -Console }

        if (Test-Path $stagingDir) {
            Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log '[NodePkg] Staging directory cleaned up.' -Console
        }
    }
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null}
}