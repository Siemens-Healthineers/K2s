# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Assists with preparing a Windows system to be used for a mixed Linux/Windows Kubernetes cluster
This script is only valid for the Small K8s Setup!!!

.DESCRIPTION
This script assists in the following actions for Small K8s:
- Downloads Kubernetes binaries (kubelet, kubeadm, flannel, nssm) at the version specified
- Registers kubelet as an nssm service. More info on nssm: https://nssm.cc/

.PARAMETER KubernetesVersion
Kubernetes version to download and use

.EXAMPLE
Without proxy
PS> .\smallsetup\InstallK8s.ps1
With proxy
PS> .\smallsetup\InstallK8s.ps1 -Proxy http://your-proxy.example.com:8888
For small systems use low memory and skip start
PS> .\smallsetup\InstallK8s.ps1 -MasterVMMemory 2GB -SkipStart
For specifying resources
PS> .\smallsetup\InstallK8s.ps1 -MasterVMMemory 8GB -MasterVMProcessorCount 6 -MasterDiskSize 80GB
For specifying DNS Addresses
PS> .\smallsetup\InstallK8s.ps1 -MasterVMMemory 8GB -MasterVMProcessorCount 6 -MasterDiskSize 80GB -DnsAddresses '8.8.8.8','8.8.4.4'
#>

Param(
    # Main parameters
    [parameter(Mandatory = $false, HelpMessage = 'K8sSetup: SmallSetup')]
    [string] $K8sSetup = 'SmallSetup',
    [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of master VM (Linux)')]
    [long] $MasterVMMemory = 8GB,
    [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for master VM (Linux)')]
    [long] $MasterVMProcessorCount = 6,
    [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of master VM (Linux)')]
    [uint64] $MasterDiskSize = 50GB,
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy,
    [parameter(Mandatory = $false, HelpMessage = 'DNS Addresses if available')]
    [string[]]$DnsAddresses = @('8.8.8.8', '8.8.4.4'),
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
    [switch] $DeleteFilesForOfflineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Force the installation online. This option is needed if the files for an offline installation are available but you want to recreate them.')]
    [switch] $ForceOnlineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'The path to the vhdx with Ubuntu inside.')]
    [string] $LinuxVhdxPath = '',
    [parameter(Mandatory = $false, HelpMessage = 'The IP address of the Linux VM with Ubuntu inside.')]
    [string] $LinuxVMIP = '',
    [parameter(Mandatory = $false, HelpMessage = 'The user name to access the Linux VM with Ubuntu inside.')]
    [string] $LinuxVMUsername = '',
    [parameter(Mandatory = $false, HelpMessage = 'The password associated with the user name to access the Linux VM with Ubuntu inside.')]
    [string] $LinuxVMUserPwd = '',

    # These are specific developer options
    [parameter(Mandatory = $false, HelpMessage = 'Exit after initial checks')]
    [switch] $CheckOnly = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Output every line that gets executed')]
    [switch] $Trace = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Do not call the StartK8s at end')]
    [switch] $SkipStart = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Host-GW or VXLAN, Host-GW: true, false for VXLAN')]
    [bool] $HostGW = $true,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Restart N number of times after Install')]
    [long] $RestartAfterInstallCount = 0,
    [parameter(Mandatory = $false, HelpMessage = 'Use WSL2 for hosting KubeMaster VM')]
    [switch] $WSL = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Append to log file (do not start from scratch)')]
    [switch] $AppendLogFile = $false
)


# load global settings
&$PSScriptRoot\common\GlobalVariables.ps1

# import global functions
. $PSScriptRoot\common\GlobalFunctions.ps1

Import-Module "$PSScriptRoot/ps-modules/log/log.module.psm1"

Initialize-Logging -ShowLogs:$ShowLogs

$ErrorActionPreference = 'Continue'
if ($Trace) {
    Set-PSDebug -Trace 1
}

$installStopwatch = [system.diagnostics.stopwatch]::StartNew()

#cleanup old logs
if ( -not  $AppendLogFile) {
    Remove-Item -Path $global:k2sLogFile -Force -Recurse -ErrorAction SilentlyContinue
}

Write-Log "Using Master VM ProcessorCount: $MasterVMProcessorCount"

# check memory
if ( $MasterVMMemory -lt 2GB ) {
    Write-Log 'SmallSetup needs minimal 2GB main memory, you have passed a lower value!'
    throw 'Memory passed to low'
}
Write-Log "Using Master VM Memory: $([math]::round($MasterVMMemory/1GB, 2))GB"

# check disk
if ( $MasterDiskSize -lt 50GB ) {
    Write-Log 'SmallSetup needs minimal 50GB disk space, you have passed a lower value!'
    throw 'Disk size passed to low'
}
Write-Log "Using Master VM Diskspace: $([math]::round($MasterDiskSize/1GB, 2))GB"

Set-EnvVars

Addk2sToDefenderExclusion

Stop-InstallationIfDockerDesktopIsRunning

if ( $K8sSetup -eq 'SmallSetup' ) {
    Write-Log 'Installing K2s'
}

$UseDockerBackend = $false
if ($UseDockerBackend) {
    Write-Log 'Docker Runtime and Build Environment'
    $UseContainerd = $false
}
else {
    Write-Log 'Containerd Runtime, Docker Build Environment'
    $UseContainerd = $true
}

$global:HeaderLineShown = $true

################################ SCRIPT START ###############################################

# make sure we are at the right place for install
Set-Location $global:KubernetesPath

# set defaults for unset arguments
$KubernetesVersion = $global:KubernetesVersion
if (! $KubernetesVersion) {
    $KubernetesVersion = 'v1.25.13'
}

# check prerequisites
Write-Log 'Running some health checks before installation...'

$installationDirectoryType = Get-Item "$global:KubernetesPath" | Select-Object -ExpandProperty LinkType
if ($null -ne $installationDirectoryType) {
    throw "Your installation directory '$global:KubernetesPath' is of type '$installationDirectoryType'. Only normal directories are supported."
}

$ReleaseId = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild
if ($ReleaseId -lt 17763) {
    Write-Log "SmallSetup needs minimal Windows Version 1809, you have $ReleaseId"
    throw "Windows release $ReleaseId not usable"
}

Enable-MissingWindowsFeatures $([bool]$WSL)

if ($WSL) {
    Write-Log 'vEthernet (WSL) switch will be reconfigured! Your existing WSL distros will not work properly until you stop the cluster.'
    Write-Log 'Configuring WSL2'
    Set-WSL
}

Test-ProxyConfiguration

$runningVMs = Get-VM -ErrorAction SilentlyContinue | Where-Object { $_.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running }
if ($runningVMs) {
    Write-Log 'Active Hyper-V VM:'
    Write-Log $($runningVMs | Select-Object -Property Name)
    if ($runningVMs | Where-Object Name -eq 'minikube') {
        throw "Minikube must be stopped before running the installer, do 'minikube stop'"
    }
}

if (Get-VM -ErrorAction SilentlyContinue -Name $global:VMName) {
    throw "$global:VMName VM must not exist when running the installer, do UninstallK8s.ps1 first"
}

if ($CheckOnly) {
    Write-Log 'Early exit (CheckOnly)'
    exit
}


Write-Log 'Starting installation...'

Set-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_WSL -Value $([bool]$WSL)
Set-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_Containerd -Value $UseContainerd
Set-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_SetupType -Value $global:SetupType_k2s

$linuxOsType = $global:LinuxOsType_DebianCloud
if (!([string]::IsNullOrWhiteSpace($LinuxVhdxPath))) {
    if (!(Test-Path $LinuxVhdxPath)) {
        throw "The specified file in the path '`$LinuxVhdxPath' does not exist"
    }
    $fileExtension = (Get-Item $LinuxVhdxPath).Extension
    if (!($fileExtension -eq '.vhdx')) {
        throw ('Disk is not a vhdx or vhd disk.' )
    }

    $linuxOsType = $global:LinuxOsType_Ubuntu
}
Set-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_LinuxOsType -Value $linuxOsType

Write-Log 'Setting up Windows worker node' -Console

# Install loopback adapter for l2bridge
Import-Module "$global:KubernetesPath\smallsetup\LoopbackAdapter.psm1" -Force
New-LoopbackAdapter -Name $global:LoopbackAdapter -DevConExe $global:DevconExe | Out-Null
Set-LoopbackAdapterProperties -Name $global:LoopbackAdapter -IPAddress $global:IP_LoopbackAdapter -Gateway $global:Gateway_LoopbackAdapter

&"$global:KubernetesPath\smallsetup\windowsnode\DeployWindowsNodeArtifacts.ps1" -KubernetesVersion $KubernetesVersion -Proxy "$Proxy" -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation -ForceOnlineInstallation $ForceOnlineInstallation -SetupType $global:SetupType_k2s

&"$global:KubernetesPath\smallsetup\windowsnode\publisher\PublishNssm.ps1"

if (!(Test-Path "$global:DockerExe") -or !(Get-Service docker -ErrorAction SilentlyContinue)) {
    $autoStartDockerd = !$UseContainerd
    &"$global:KubernetesPath\smallsetup\windowsnode\publisher\PublishDocker.ps1"
    &"$global:KubernetesPath\smallsetup\windowsnode\InstallDockerWin10.ps1" -AutoStart:$autoStartDockerd -Proxy "$Proxy"
}

# setup host as a worker node (installs nssm for starting kubelet, flannel and kubeproxy)
&"$global:KubernetesPath\smallsetup\windowsnode\SetupNode.ps1" -KubernetesVersion $KubernetesVersion -MasterIp $global:IP_Master -MinSetup:$true -HostGW:$HostGW -Proxy:"$Proxy"

# install containerd
if ($UseContainerd) {
    &"$global:KubernetesPath\smallsetup\windowsnode\InstallContainerd.ps1" -Proxy "$Proxy"
    &"$global:KubernetesPath\smallsetup\windowsnode\publisher\PublishWindowsImages.ps1"
}

if (!$UseContainerd) {
    # restart docker because it hangs often
    if ($(Get-Service -Name kubelet -ErrorAction SilentlyContinue).Status -eq 'Running') {
        Stop-Service -Name kubelet
    }
    Restart-Service docker
}

# install K8s services
&"$global:KubernetesPath\smallsetup\windowsnode\publisher\PublishKubetools.ps1"
&"$global:KubernetesPath\smallsetup\windowsnode\InstallKubelet.ps1" -UseContainerd:$UseContainerd
&"$global:KubernetesPath\smallsetup\windowsnode\publisher\PublishFlannel.ps1"
&"$global:KubernetesPath\smallsetup\windowsnode\InstallFlannel.ps1"
&"$global:KubernetesPath\smallsetup\windowsnode\InstallKubeProxy.ps1"
&"$global:KubernetesPath\smallsetup\windowsnode\publisher\PublishWindowsExporter.ps1"
&"$global:KubernetesPath\smallsetup\windowsnode\InstallWinExporter.ps1"
&"$global:KubernetesPath\smallsetup\windowsnode\InstallHttpProxy.ps1" -Proxy $Proxy
&"$global:KubernetesPath\smallsetup\windowsnode\publisher\PublishDnsProxy.ps1"
&"$global:KubernetesPath\smallsetup\windowsnode\InstallDnsProxy.ps1"
&"$global:KubernetesPath\smallsetup\windowsnode\publisher\PublishPuttytools.ps1"

# remove folder with windows node artifacts since all of them are already published to the expected locations
Remove-Item "$global:WindowsNodeArtifactsDirectory" -Recurse -Force -ErrorAction SilentlyContinue

# reset some services
&"$global:NssmInstallDirectory\nssm" set kubeproxy Start SERVICE_DEMAND_START | Out-Null
&"$global:NssmInstallDirectory\nssm" set kubelet Start SERVICE_DEMAND_START | Out-Null
&"$global:NssmInstallDirectory\nssm" set flanneld Start SERVICE_DEMAND_START | Out-Null

if ($WSL) {
    Write-Log "Setting up $global:VMName Distro" -Console
}
else {
    Write-Log "Setting up $global:VMName VM" -Console
}

# create the linux master
$ProgressPreference = 'SilentlyContinue'

$reuseExistingLinuxComputer = !([string]::IsNullOrWhiteSpace($LinuxVMIP))
Set-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_ReuseExistingLinuxComputerForMasterNode -Value $reuseExistingLinuxComputer
if ($reuseExistingLinuxComputer) {
    Write-Log "Configuring computer with IP '$LinuxVMIP' to act as Master Node"
    &"$global:KubernetesPath\smallsetup\linuxnode\ubuntu\ExistingUbuntuComputerAsMasterNodeInstaller.ps1" -IpAddress $LinuxVMIP -UserName $LinuxVMUsername -UserPwd $LinuxVMUserPwd -Proxy $Proxy
    Write-Log "Finished configuring computer with IP '$LinuxVMIP' to act as Master Node"

    Wait-ForSSHConnectionToLinuxVMViaSshKey
}
else {
    $vm = Get-Vm -Name $global:VMName -ErrorAction SilentlyContinue
    if ( !($vm) ) {
        # use the local httpproxy for the linux master VM
        $transparentproxy = 'http://' + $global:IP_NextHop + ':8181'
        Write-Log "Local httpproxy proxy was set and will be used for linux VM: $transparentproxy"
        Install-AndInitKubemaster -VMStartUpMemory $MasterVMMemory -VMProcessorCount $MasterVMProcessorCount -VMDiskSize $MasterDiskSize -InstallationStageProxy $Proxy -OperationStageProxy $transparentproxy -HostGW $HostGW -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation -ForceOnlineInstallation $ForceOnlineInstallation -WSL:$WSL -LinuxVhdxPath $LinuxVhdxPath -LinuxUserName $LinuxVMUsername -LinuxUserPwd $LinuxVMUserPwd
    }
    Write-Log 'VM is now available'
}

Write-Log 'Joining Nodes'

Copy-KubeConfigFromMasterNode

# set context on windows host (add to existing contexts)
&"$global:KubernetesPath\smallsetup\common\AddContextToConfig.ps1"

Invoke-HookAfterVmInitialized -AdditionalHooksDir $AdditionalHooksDir

# try to join host windows node
Write-Log 'starting the join process'
&"$global:KubernetesPath\smallsetup\common\JoinWindowsHost.ps1"

# set new limits for the windows node for disk pressure
# kubelet is running now (caused by JoinWindowsHost.ps1), so we stop it. Will be restarted in StartK8s.ps1.
Stop-Service kubelet
$kubeletconfig = $global:KubeletConfigDir + '\config.yaml' 
Write-Log "kubelet config: $kubeletconfig"
$content = Get-Content $kubeletconfig
$content | ForEach-Object { $_ -replace 'evictionPressureTransitionPeriod:',
    "evictionHard:`r`n  nodefs.available: 8Gi`r`n  imagefs.available: 8Gi`r`nevictionPressureTransitionPeriod:" } |
Set-Content $kubeletconfig

# add ip to hosts file
&"$global:KubernetesPath\smallsetup\AddToHosts.ps1"

# show results
Write-Log "Current state of kubernetes nodes:`n"
Start-Sleep 2
kubectl get nodes -o wide

Write-Log "Collecting kubernetes images and storing them to $global:KubernetesImagesJson."
$imageFunctionsModulePath = "$PSScriptRoot\helpers\ImageFunctions.module.psm1"
Import-Module $imageFunctionsModulePath -DisableNameChecking
Write-KubernetesImagesIntoJson

if (! $SkipStart) {
    Write-Log 'Starting Kubernetes System'
    & "$global:KubernetesPath\smallsetup\StartK8s.ps1" -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs
}

if ( ($RestartAfterInstallCount -gt 0) -and (! $SkipStart) ) {
    $restartCount = 0;

    while ($true) {
        $restartCount++
        Write-Log "Restarting Kubernetes System (iteration #$restartCount):"

        & "$global:KubernetesPath\smallsetup\StopK8s.ps1" -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs
        Start-Sleep 10 # Wait for renew of IP

        & "$global:KubernetesPath\smallsetup\StartK8s.ps1" -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs
        Start-Sleep -s 5

        if ($restartCount -eq $RestartAfterInstallCount) {
            Write-Log 'Restarting Kubernetes System Completed'
            break;
        }
    }
}

Invoke-Hook -HookName 'AfterBaseInstall' -AdditionalHooksDir $AdditionalHooksDir

# show results
Write-Log "Current state of kubernetes nodes:`n"
Start-Sleep 2
kubectl get nodes -o wide

Write-Log '---------------------------------------------------------------'
Write-Log "K2s setup finished.   Total duration: $('{0:hh\:mm\:ss}' -f $installStopwatch.Elapsed )"
Write-Log '---------------------------------------------------------------'

Write-RefreshEnvVariables

