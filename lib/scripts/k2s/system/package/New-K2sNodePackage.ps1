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

Import-Module $infraModule, $nodeModule

if ($EncodeStructuredOutput) {
    Initialize-Logging -ShowLogs:$false
} else {
    Initialize-Logging -ShowLogs:$ShowLogs
}

$distributionKey = $OS.ToLower()

$kubePath    = Get-KubePath
$kubeBinPath = Get-KubeBinPath

Write-Log "[NodePkg] Starting node package creation for OS='$OS'" -Console
Write-Log "[NodePkg] Distribution key: $distributionKey" -Console
Write-Log "[NodePkg] Target directory: $TargetDirectory" -Console
Write-Log "[NodePkg] Output zip: $ZipPackageFileName" -Console

# Initialize variables for VM and network provisioning
$tempPath = [System.IO.Path]::GetTempPath()
$stagingDir = Join-Path $tempPath "k2s-node-pkg-$([guid]::NewGuid().ToString().Substring(0, 8))"
$vmName = "k2s-nodepkg-$distributionKey-$(Get-Random -Maximum 9999)"
$switchName = "k2s-node-$distributionKey-$(Get-Random -Maximum 9999)"
$natName = "k2s-node-$distributionKey-$(Get-Random -Maximum 9999)"
$vhdxName = "$vmName.vhdx"
$isoName = "$vmName.iso"
$netIntf = "eth0"
$randomSubnet = Get-Random -Minimum 100 -Maximum 200
$hostIp = "192.168.$randomSubnet.1"
$guestIp = "192.168.$randomSubnet.10"
$prefixLen = 24
$natIp = "192.168.$randomSubnet.0"
$sshUser = "admin"
$sshPwd = "admin"

$provisioningDir = Join-Path $stagingDir "provisioning"
$downloadsDir = Join-Path $stagingDir "downloads"
$packagesDir = Join-Path $stagingDir "packages"
$k8sPkgDir = Join-Path $packagesDir "kubernetes"
$buildahPkgDir = Join-Path $packagesDir "buildah"
$remoteK8sPkgDir = "/tmp/k2s-k8s-packages"
$remoteBuildahPkgDir = "/tmp/k2s-buildah-packages"
$vmProvisioningStarted = $false

New-Item -Path $stagingDir -ItemType Directory -Force | Out-Null
New-Item -Path $provisioningDir -ItemType Directory -Force | Out-Null
New-Item -Path $downloadsDir -ItemType Directory -Force | Out-Null
New-Item -Path $packagesDir -ItemType Directory -Force | Out-Null
New-Item -Path $k8sPkgDir -ItemType Directory -Force | Out-Null
New-Item -Path $buildahPkgDir -ItemType Directory -Force | Out-Null

$inProvisioningVhdxPath = Join-Path $provisioningDir $vhdxName

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
# Resolve paths and versions
# ---------------------------------------------------------------------------
$k8sVersion  = Get-DefaultK8sVersion

$cloudInitTemplatePath = Join-Path $kubePath 'lib\modules\k2s\k2s.node.module\linuxnode\baseimage\cloud-init-templates'
$isoBuilderTool        = Join-Path $kubeBinPath 'cloudinitisobuilder.exe'

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
            Remove-Item $packagesDir -Recurse -Force -ErrorAction SilentlyContinue

            # Copy kubernetes and buildah deb packages from kubemaster to the local staging dir
            Copy-DebPackagesFromControlPlaneToWindowsHost -TargetPath $packagesDir

            # Create zip at the requested output location
            New-Item -Path $TargetDirectory -ItemType Directory -Force | Out-Null
            Compress-Archive -Path $packagesDir -DestinationPath $zipTarget -Force
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

    # -----------------------------------------------------------------------
    # Phase 1 - Create ephemeral Hyper-V VM with cloud-init
    # -----------------------------------------------------------------------
    Write-Log "[NodePkg] === Phase 1: Creating Hyper-V VM for '$distributionKey' ===" -Console

    $vmParams = @{
        VmName               = $vmName
        VhdxName             = $vhdxName
        VMMemoryStartupBytes = 2GB
        VMProcessorCount     = 2
        VMDiskSize           = 20GB
    }
    $netParams = @{
        Proxy              = $Proxy
        SwitchName         = $switchName
        HostIpAddress      = $hostIp
        HostIpPrefixLength = $prefixLen
        NatName            = $natName
        NatIpAddress       = $natIp
        DnsIpAddresses     = '8.8.8.8'
    }
    $isoParams = @{
        IsoFileCreatorToolPath = $isoBuilderTool
        IsoFileName            = $isoName
        SourcePath             = $cloudInitTemplatePath
        Hostname               = "k2s-nodepkg-$distributionKey"
        NetworkInterfaceName   = $netIntf
        IPAddressVM            = $guestIp
        IPAddressGateway       = $hostIp
        UserName               = $sshUser
        UserPwd                = $sshPwd
    }
    $dirParams = @{
        DownloadsDirectory    = $downloadsDir
        ProvisioningDirectory = $provisioningDir
    }

    New-LinuxCloudBasedVirtualMachine `
        -VirtualMachineParams     $vmParams `
        -NetworkParams            $netParams `
        -IsoFileParams            $isoParams `
        -WorkingDirectoriesParams $dirParams `
        -TargetDistribution    $distributionKey
    $vmProvisioningStarted = $true

    # -----------------------------------------------------------------------
    # Phase 2 - Start VM and wait for heartbeat
    # -----------------------------------------------------------------------
    Write-Log "[NodePkg] === Phase 2: Starting VM '$vmName' ===" -Console
    Start-VirtualMachineAndWaitForHeartbeat -Name $vmName

    # -----------------------------------------------------------------------
    # Phase 3 - Wait for SSH to become available
    # -----------------------------------------------------------------------
    Write-Log "[NodePkg] === Phase 3: Waiting for SSH ($sshUser@$guestIp) ===" -Console
    Wait-ForSshPossible `
        -User                         "$sshUser@$guestIp" `
        -UserPwd                      $sshPwd `
        -SshTestCommand               'which ls' `
        -ExpectedSshTestCommandResult '/usr/bin/ls'

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

    $remoteUser = "$sshUser@$guestIp"
    $remoteK8sDebCount = (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "ls -1 $remoteK8sPkgDir/*.deb 2>/dev/null | wc -l" -RemoteUser $remoteUser -RemoteUserPwd $sshPwd -IgnoreErrors).Output
    $remoteBuildahDebCount = (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "ls -1 $remoteBuildahPkgDir/*.deb 2>/dev/null | wc -l" -RemoteUser $remoteUser -RemoteUserPwd $sshPwd -IgnoreErrors).Output
    Write-Log "[NodePkg] Remote package counts before copy: kubernetes=$($remoteK8sDebCount.Trim()), buildah=$($remoteBuildahDebCount.Trim())" -Console

    # -----------------------------------------------------------------------
    # Phase 6 - Copy packages from VM back to Windows host
    # -----------------------------------------------------------------------
    Write-Log "[NodePkg] === Phase 7: Copying packages from VM to Windows ===" -Console
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
    # Phase 7 - Create output zip
    # -----------------------------------------------------------------------
    Write-Log "[NodePkg] === Phase 8: Creating output zip ===" -Console
    New-Item -Path $TargetDirectory -ItemType Directory -Force | Out-Null
    $zipTarget = Join-Path $TargetDirectory $ZipPackageFileName
    if (Test-Path $zipTarget) { Remove-Item $zipTarget -Force }
    Compress-Archive -Path $packagesDir -DestinationPath $zipTarget -Force
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