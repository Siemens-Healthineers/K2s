# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs the Multi-VM K8s setup.

.DESCRIPTION
Target setup:
+ configured Windows host (kubectl installed, etc.)
+ Linux VM on Windows host as master and worker node
+ Windows VM on Windows host as worker node

This script assists in the following actions for Small K8s:
- Installing the VM images
- creating a K8s cluster based on those VMs

.PARAMETER WindowsImage
Path to the Windows ISO image to use for Windows VM (mandatory)

.PARAMETER WinVMStartUpMemory
Startup Memory Size of Windows VM

.PARAMETER WinVMDiskSize
Virtual hard disk size of Windows VM

.PARAMETER WinVMProcessorCount
Number of Virtual Processors of Windows VM

.PARAMETER MasterVMMemory
Startup Memory Size of master VM (Linux)

.PARAMETER MasterDiskSize
Virtual hard disk size of master VM (Linux)

.PARAMETER MasterVMProcessorCount
Number of Virtual Processors for master VM (Linux)

.PARAMETER Proxy
Proxy to use

.PARAMETER DnsAddresses
DNS addresses

.PARAMETER SkipStart
Whether to skip starting the K8s cluster after successful installation

.PARAMETER ShowLogs
Show all logs in terminal

.PARAMETER AdditionalHooksDir
Directory containing additional hooks to be executed after local hooks are executed.

.PARAMETER Offline
Perform the installation of the Linux VM without donwloading artifacts from the internet.

.EXAMPLE
PS> .\lib\scripts\multivm\install\Install.ps1 -WindowsImage 'c:\temp\en_windows_10_business_editions_version_20h2_x64_dvd_4788fb7c.iso'

.EXAMPLE
PS> .\lib\scripts\multivm\install\Install.ps1 -SkipStart -WindowsImage 'c:\temp\en_windows_10_business_editions_version_20h2_x64_dvd_4788fb7c.iso'
Install Multi-VM setup without starting the K8s cluster

.EXAMPLE
PS> .\lib\scripts\multivm\install\Install.ps1 -VMStartUpMemory 3GB -VMDiskSize 40GB -VMProcessorCount 4 -WindowsImage 'c:\temp\en_windows_10_business_editions_version_20h2_x64_dvd_4788fb7c.iso'
For low end systems use less memory, disk space and processor count

.EXAMPLE
PS> .\lib\scripts\multivm\install\Install.ps1 -Proxy http://your-proxy.example.com:8888 -WindowsImage 'c:\temp\en_windows_10_business_editions_version_20h2_x64_dvd_4788fb7c.iso'
With Proxy

.EXAMPLE
PS> .\lib\scripts\multivm\install\Install.ps1 -Proxy http://your-proxy.example.com:8888 -DnsAddresses '8.8.8.8','8.8.4.4' -WindowsImage 'c:\temp\en_windows_10_business_editions_version_20h2_x64_dvd_4788fb7c.iso'
For specifying DNS Addresses

.EXAMPLE
PS> .\lib\scripts\multivm\install\Install.ps1 -AdditonalHooks 'C:\AdditionalHooks' -WindowsImage 'c:\temp\en_windows_10_business_editions_version_20h2_x64_dvd_4788fb7c.iso'
For specifying additional hooks to be executed.

To install Linux-only:
PS> .\lib\scripts\multivm\install\Install.ps1 -LinuxOnly
#>

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Windows ISO image path (mandatory if not Linux-only)')]
    [string] $WindowsImage,
    [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of Windows VM')]
    [long] $WinVMStartUpMemory = 4GB,
    [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of Windows VM')]
    [long] $WinVMDiskSize = 50GB,
    [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors of Windows VM')]
    [long] $WinVMProcessorCount = 4,
    [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of master VM (Linux)')]
    [long] $MasterVMMemory = 6GB,
    [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of master VM (Linux)')]
    [uint64] $MasterDiskSize = 50GB,
    [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for master VM (Linux)')]
    [long] $MasterVMProcessorCount = 4,
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy,
    [parameter(Mandatory = $false, HelpMessage = 'DNS Addresses if available')]
    [string[]]$DnsAddresses = @('8.8.8.8', '8.8.4.4'),
    [parameter(Mandatory = $false, HelpMessage = 'Do not call the StartK8s at end')]
    [switch] $SkipStart = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
    [switch] $DeleteFilesForOfflineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Force the installation online. This option is needed if the files for an offline installation are available but you want to recreate them.')]
    [switch] $ForceOnlineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Use WSL2 for hosting KubeMaster VM')]
    [switch] $WSL = $false,
    [parameter(Mandatory = $false, HelpMessage = 'No Windows worker node will be set up')]
    [switch] $LinuxOnly = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Append to log file (do not start from scratch)')]
    [switch] $AppendLogFile = $false
)


$infraModule = "$PSScriptRoot/../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot/../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$multivmModule = "$PSScriptRoot/../../../modules/k2s/k2s.multivm.module/k2s.multivm.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule, $multivmModule

$KubernetesVersion = 'v1.25.13'
$script:SetupType = 'MultiVMK8s'
$multiVMWindowsVMName = 'WinNode' # WARNING: VM name must not exceed a certain length, otherwise unattend.xml file parsing will fail!

#################################################################################################
# FUNCTIONS                                                                                     #
#################################################################################################

function Install-WindowsVM() {
    $switchname = ''
    if ($WSL) {
        $switchname = $global:WSLSwitchName
    }
    else {
        $controlPlaneSwitchName = Get-ControlPlaneNodeDefaultSwitchName
        $switchname = $controlPlaneSwitchName
    }
    $kubeSwitchIp = Get-ConfiguredKubeSwitchIP
    $multivmRootConfig = Get-RootConfigMultivm
    $multiVMWinNodeIP = $multivmRootConfig.psobject.properties['multiVMK8sWindowsVMIP'].value

    Write-Log "Creating VM $multiVMWindowsVMName..."
    Write-Log "Using $WinVMStartUpMemory of memory for VM"
    Write-Log "Using $WinVMDiskSize of virtual disk space for VM"
    Write-Log "Using $WinVMProcessorCount of virtual processor count for VM"
    Write-Log "Using image: $WindowsImage"
    Write-Log 'Using virtio image: none'

    Initialize-WinVM `
        -Name $multiVMWindowsVMName `
        -Image $WindowsImage `
        -VMStartUpMemory $WinVMStartUpMemory `
        -VMDiskSize $WinVMDiskSize `
        -VMProcessorCount $WinVMProcessorCount `
        -Proxy $Proxy `
        -DnsAddresses $DnsAddresses `
        -SwitchName $switchname `
        -SwitchIP $kubeSwitchIp `
        -CreateSwitch $false `
        -IpAddress $multiVMWinNodeIP

    Initialize-WinVMNode -KubernetesVersion $KubernetesVersion `
        -HostGW:$true `
        -HostVM:$true `
        -Proxy:"$Proxy" `
        -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation `
        -ForceOnlineInstallation $ForceOnlineInstallation
}



function Install-KubectlOnHost() {
    $previousKubernetesVersion = Get-InstalledKubernetesVersion

    if (!(Test-Path "$global:ExecutableFolderPath")) {
        New-Item -Path $global:ExecutableFolderPath -ItemType Directory | Out-Null
    }

    # TODO: clone from SetupNode.ps1
    if (!(Test-Path "$global:ExecutableFolderPath\kubectl.exe") -or ($previousKubernetesVersion -ne $global:KubernetesVersion)) {
        DownloadFile "$global:ExecutableFolderPath\kubectl.exe" https://dl.k8s.io/release/$global:KubernetesVersion/bin/windows/amd64/kubectl.exe $true
        # put a second copy in the bin folder, which is in the PATH
        Copy-Item -Force "$global:ExecutableFolderPath\kubectl.exe" "$global:KubernetesPath\bin\kubectl.exe"
    }
}

function Install-PuttyTools() {
    if (Test-Path($global:WindowsNodeArtifactsDownloadsDirectory)) {
        Write-Log "Remove content of folder '$global:WindowsNodeArtifactsDownloadsDirectory'"
        Remove-Item "$global:WindowsNodeArtifactsDownloadsDirectory\*" -Recurse -Force
    }
    else {
        Write-Log "Create folder '$global:WindowsNodeArtifactsDownloadsDirectory'"
        mkdir $global:WindowsNodeArtifactsDownloadsDirectory | Out-Null
    }
    &$PSScriptRoot\..\windowsnode\downloader\DownloadPuttytools.ps1 -Proxy $Proxy
    if (-Not(Test-Path "$global:WindowsNodeArtifactsDirectory\$global:WindowsNode_PuttytoolsDirectory")) {
        mkdir "$global:WindowsNodeArtifactsDirectory\$global:WindowsNode_PuttytoolsDirectory" | Out-Null
    }
    Copy-Item -Path "$global:WindowsNodeArtifactsDownloadsDirectory\$global:WindowsNode_PuttytoolsDirectory" -Destination "$global:WindowsNodeArtifactsDirectory" -Recurse -Force
    &$PSScriptRoot\..\windowsnode\publisher\PublishPuttytools.ps1
    if (Test-Path($global:WindowsNodeArtifactsDownloadsDirectory)) {
        Write-Log "Remove folder '$global:WindowsNodeArtifactsDownloadsDirectory'"
        Remove-Item $global:WindowsNodeArtifactsDownloadsDirectory -Force -Recurse
    }
    if (Test-Path("$global:WindowsNodeArtifactsDirectory\$global:WindowsNode_PuttytoolsDirectory")) {
        Write-Log "Remove folder '$global:WindowsNodeArtifactsDirectory\$global:WindowsNode_PuttytoolsDirectory'"
        Remove-Item "$global:WindowsNodeArtifactsDirectory\$global:WindowsNode_PuttytoolsDirectory" -Force -Recurse
    }
}

function Add-KubeContext() {
    # set context on windows host (add to existing contexts)
    &"$global:KubernetesPath\smallsetup\common\AddContextToConfig.ps1"
}

function Save-ControlPlaneNodeHostnameIntoWinVM($session) {
    $hostname = Get-ControlPlaneNodeHostname
    Write-Log "Saving VM hostname '$hostname' into Windows node ..."
    Invoke-Command -Session $session {
        Set-Location "$env:SystemDrive\k"
        Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

        # load global settings
        &$env:SystemDrive\k\smallsetup\common\GlobalVariables.ps1
        # import global functions
        . $env:SystemDrive\k\smallsetup\common\GlobalFunctions.ps1
        Import-Module $env:SystemDrive\k\smallsetup\ps-modules\log\log.module.psm1
        Initialize-Logging -Nested:$true

        Save-ControlPlaneNodeHostname($using:hostname)
    }
    Write-Log '  done.'
}

function Join-WindowsNode($session) {
    Write-Log 'Joining Windows node ...'

    $switch = $global:SwitchName

    $ErrorActionPreference = 'Continue'

    Invoke-Command -Session $session {
        Set-Location "$env:SystemDrive\k"
        Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

        # disable IPv6 completely
        Get-NetAdapterBinding -ComponentID ms_tcpip6 | ForEach-Object {
            Disable-NetAdapterBinding -Name $_.Name -ComponentID ms_tcpip6
        }

        # load global settings
        &$env:SystemDrive\k\smallsetup\common\GlobalVariables.ps1
        # import global functions
        . $env:SystemDrive\k\smallsetup\common\GlobalFunctions.ps1
        Import-Module $env:SystemDrive\k\smallsetup\ps-modules\log\log.module.psm1
        Initialize-Logging -Nested:$true

        &"$global:KubernetesPath\smallsetup\common\JoinWindowsHost.ps1" -Nested:$true
    }

    $ErrorActionPreference = 'Stop'

    Write-Log 'Windows node joined.'
}

function Set-DiskPressureLimitsOnWindowsNode($session) {
    Write-Log 'Setting disk pressure limits on Windows node ...'

    Invoke-Command -Session $session {
        Set-Location "$env:SystemDrive\k"
        Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

        $kubeletConfig = "$global:KubeletConfigDir\config.yaml"
        Write-Log "Using kubelet config: $kubeletConfig"

        # set new limits for the windows node for disk pressure
        # kubelet is running now (caused by JoinWindowsHost.ps1), so we stop it. Will be restarted in StartK8s.ps1.
        Stop-Service kubelet
        $content = Get-Content $kubeletConfig
        $content | ForEach-Object { $_ -replace 'evictionPressureTransitionPeriod:',
            "evictionHard:`r`n  nodefs.available: 8Gi`r`n  imagefs.available: 8Gi`r`nevictionPressureTransitionPeriod:" } |
        Set-Content $kubeletConfig
    }

    Write-Log 'Disk pressure limits on Windows node set.'
}

function Add-IPsToHostsFiles($session) {
    Write-Log 'Adding IPs to hosts files ...'

    & "$global:KubernetesPath\smallsetup\AddToHosts.ps1" -DesiredIP $global:IP_Master -Hostname 'k2s.cluster.net'

    if ($LinuxOnly -ne $true) {
        & "$global:KubernetesPath\smallsetup\AddToHosts.ps1" -DesiredIP $global:MultiVMWinNodeIP -Hostname $global:MultiVMHostName

        $masterIp = $global:IP_Master

        Invoke-Command -Session $session {
            Set-Location "$env:SystemDrive\k"
            Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

            # load global settings
            &$env:SystemDrive\k\smallsetup\common\GlobalVariables.ps1
            # import global functions
            . $env:SystemDrive\k\smallsetup\common\GlobalFunctions.ps1
            Import-Module $env:SystemDrive\k\smallsetup\ps-modules\log\log.module.psm1
            Initialize-Logging -Nested:$true

            & "$global:KubernetesPath\smallsetup\AddToHosts.ps1" -DesiredIP $using:masterIp -Hostname 'k2s.cluster.net'
        }
    }

    Write-Log 'IPs added to hosts files.'
}

function Write-K8sNodesStatus {
    $retryIteration = 0
    $ErrorActionPreference = 'Continue'
    while ($true) {
        #Check whether node information is available from the cluster
        kubectl get nodes 2>$null | Out-Null
        if ($?) {
            Write-Log 'Current state of kubernetes nodes:'
            kubectl get nodes -o wide
            break
        }
        else {
            Write-Log "Iteration: $retryIteration Node status not available yet, retrying in a moment..."
            Start-Sleep -Seconds 5
        }

        if ($retryIteration -eq 10) {
            throw "Unable to get cluster node status information"
        }
        $retryIteration++
    }
    $ErrorActionPreference = 'Stop'
}

function Repair-WindowsAutoConfigOnVM($session) {
    Invoke-Command -Session $session {
        Set-Location "$env:SystemDrive\k"
        Set-ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue

        # load global settings
        &$env:SystemDrive\k\smallsetup\common\GlobalVariables.ps1

        # import global functions
        . $env:SystemDrive\k\smallsetup\common\GlobalFunctions.ps1
        Import-Module $env:SystemDrive\k\smallsetup\ps-modules\log\log.module.psm1
        Initialize-Logging -Nested:$true

        & "$global:KubernetesPath\smallsetup\FixAutoconfiguration.ps1"
    }
}

function Enable-SSHRemotingViaSSHKeyToWinNode ($session) {
    Invoke-Command -Session $session {
        Set-Location "$env:SystemDrive\k"
        Set-ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue

        if ($using:Proxy -ne "") {
            pwsh -Command "`$ENV:HTTPS_PROXY='$using:Proxy';Install-Module -Name Microsoft.PowerShell.RemotingTools -Force -Confirm:`$false"
        } else {
            pwsh -Command "Install-Module -Name Microsoft.PowerShell.RemotingTools -Force -Confirm:`$false"
        }

        pwsh -Command "Get-InstalledModule"
        pwsh -Command "Enable-SSHRemoting -Force"

        Restart-Service sshd
    }
}

function Disable-PasswordAuthenticationToWinNode () {
    $session = Open-RemoteSessionViaSSHKey $global:Admin_WinNode $global:WindowsVMKey

    Invoke-Command -Session $session {
        Set-Location "$env:SystemDrive\k"
        Set-ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue

        # Change password on next login
        cmd.exe /c "wmic UserAccount where name='Administrator' set Passwordexpires=true"
        cmd.exe /c "net user Administrator /logonpasswordchg:yes"

        # Disable password authentication over ssh
        Add-Content "C:\ProgramData\ssh\sshd_config" "`nPasswordAuthentication no"
        Restart-Service sshd

        # Disable WinRM
        netsh advfirewall firewall set rule name="Windows Remote Management (HTTP-In)" new enable=yes action=block
        netsh advfirewall firewall set rule group="Windows Remote Management" new enable=yes
        $winrmService = Get-Service -Name WinRM
        if ($winrmService.Status -eq "Running"){
            Disable-PSRemoting -Force
        }
        Stop-Service winrm
        Set-Service -Name winrm -StartupType Disabled

        # Disable Powershell Direct
        Stop-Service vmicvmsession
        Set-Service -Name vmicvmsession -StartupType Disabled
    }
}

#################################################################################################
# SCRIPT START                                                                                  #
#################################################################################################

Initialize-Logging -ShowLogs:$ShowLogs
Reset-LogFile -AppendLogFile:$AppendLogFile

$ErrorActionPreference = 'Stop'

if ($Trace) {
    Set-PSDebug -Trace 1
}

Write-Log '---------------------------------------------------------------'
Write-Log 'Multi-VM Kubernetes Installation started.'
Write-Log '---------------------------------------------------------------'

# TODO: remove, when multi-vm supports offline installation ------------------|

$offlineInstallationRequested = $false

if ($ForceOnlineInstallation -ne $true) {
    $ForceOnlineInstallation = $true
    $offlineInstallationRequested = $true
}

if ($DeleteFilesForOfflineInstallation -eq $false) {
    $DeleteFilesForOfflineInstallation = $true
    $offlineInstallationRequested = $true
}

if ($offlineInstallationRequested -eq $true) {
    Write-Log "Offline installation is currently not supported for 'multi-vm', falling back to online installation."
}

# ----------------------------------------------------------------------------|

$installStopwatch = [system.diagnostics.stopwatch]::StartNew()

if ($LinuxOnly -eq $true) {
    Write-Log 'Multi-VM setup will install Linux node only'
}
else {
    if (!$WindowsImage) {
        throw 'Windows ISO image path not specified'
    }

    if ((Test-Path $WindowsImage) -ne $true) {
        throw "Windows image ISO file '$WindowsImage' not found."
    }
}

Set-EnvVars

Add-k2sToDefenderExclusion
Stop-InstallIfDockerDesktopIsRunning

Set-ConfigSetupType -Value $script:SetupType
Set-ConfigWslFlag -Value $([bool]$WSL)
Set-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_LinuxOnly -Value ($LinuxOnly -eq $true)

$productVersion = Get-ProductVersion
$kubePath = Get-KubePath

Set-ConfigInstalledKubernetesVersion -Value $KubernetesVersion
Set-ConfigInstallFolder -Value $kubePath
Set-ConfigProductVersion -Value $productVersion

Enable-MissingWindowsFeatures $([bool]$WSL)

if ($WSL) {
    Write-Log 'vEthernet (WSL) switch will be reconfigured! Your existing WSL distros will not work properly until you stop the cluster.'
    Write-Log 'Configuring WSL2'
    Set-WSL
}

Test-ProxyConfiguration

# if ($WSL) {
#     Write-Log "Setting up $global:VMName Distro" -Console
# }
# else {
#     Write-Log "Setting up $global:VMName VM" -Console
# }

$ErrorActionPreference = 'Continue'

#Install-PuttyTools

# PREPARE LINUX VM
Initialize-LinuxNode -VMStartUpMemory $MasterVMMemory `
    -VMProcessorCount $MasterVMProcessorCount `
    -VMDiskSize $MasterDiskSize `
    -InstallationStageProxy $Proxy `
    -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation `
    -ForceOnlineInstallation $ForceOnlineInstallation `
    -WSL:$WSL

$ErrorActionPreference = 'Stop'

New-DefaultNetNat

if ($LinuxOnly -ne $true) {
    Write-Log 'Setting up WinNode worker VM' -Console

    Install-WindowsVM # needs kubeswitch being already setup with Install-Kubemaster

    #Save-ControlPlaneNodeHostnameIntoWinVM $session
}

Copy-KubeConfigFromMasterNode

Install-KubectlOnHost

Add-KubeContext

Invoke-HookAfterVmInitialized -AdditionalHooksDir $AdditionalHooksDir

Write-Log 'Joining Nodes' -Console

if ($LinuxOnly -ne $true) {
    Join-WindowsNode $session

    Set-DiskPressureLimitsOnWindowsNode $session # TODO: check if this is necessary
}

Add-IPsToHostsFiles $session

Write-K8sNodesStatus

Write-Log "Collecting kubernetes images and storing them to $global:KubernetesImagesJson."
$imageFunctionsModulePath = "$PSScriptRoot\..\helpers\ImageFunctions.module.psm1"
Import-Module $imageFunctionsModulePath -DisableNameChecking
Write-KubernetesImagesIntoJson

if ($LinuxOnly -ne $true) {
    Enable-SSHRemotingViaSSHKeyToWinNode $session
    Disable-PasswordAuthenticationToWinNode
}

& "$global:KubernetesPath\smallsetup\multivm\Stop_MultiVMK8sSetup.ps1" -ShowLogs:$ShowLogs

if (! $SkipStart) {
    Write-Log 'Starting Kubernetes system ...'
    & "$global:KubernetesPath\smallsetup\multivm\Start_MultiVMK8sSetup.ps1" -HideHeaders -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs
}

Invoke-Hook -HookName 'AfterBaseInstall' -AdditionalHooksDir $AdditionalHooksDir

Write-Log '---------------------------------------------------------------'
Write-Log "Multi-VM setup finished.  Total duration: $('{0:hh\:mm\:ss}' -f $installStopwatch.Elapsed )"
Write-Log '---------------------------------------------------------------'

Write-RefreshEnvVariables
