# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Master VM memory')]
    [long] $MasterVMMemory = 6GB,
    [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for master VM (Linux)')]
    [long] $MasterVMProcessorCount = 6,
    [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of master VM (Linux)')]
    [uint64] $MasterDiskSize = 50GB,
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
    [switch] $DeleteFilesForOfflineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Force the installation online. This option is needed if the files for an offline installation are available but you want to recreate them.')]
    [switch] $ForceOnlineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Use WSL2 for hosting KubeMaster VM')]
    [switch] $WSL = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Append to log file (do not start from scratch)')]
    [switch] $AppendLogFile = $false
)

# load global settings
&$PSScriptRoot\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\GlobalFunctions.ps1

Import-Module "$PSScriptRoot/../ps-modules/log/log.module.psm1"
Import-Module "$PSScriptRoot/../ps-modules/proxy/proxy.module.psm1"
Initialize-Logging -ShowLogs:$ShowLogs

$global:HeaderLineShown = $true
$installStopwatch = [system.diagnostics.stopwatch]::StartNew()

Write-Log 'Installing Build Only Environment'
Set-EnvVars

$Proxy = Get-OrUpdateProxyServer -Proxy:$Proxy

$ErrorActionPreference = 'Continue'

#cleanup old logs
if( -not  $AppendLogFile) {
    Remove-Item -Path $global:k2sLogFile -Force -Recurse -ErrorAction SilentlyContinue
}

Addk2sToDefenderExclusion

Stop-InstallationIfDockerDesktopIsRunning

Enable-MissingWindowsFeatures $([bool]$WSL)

if ($WSL) {
    Write-Log 'vEthernet (WSL) switch will be reconfigured! Your existing WSL distros will not work properly until you stop the cluster.'
    Write-Log 'Configuring WSL2'
    Set-WSL
}

Set-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_WSL -Value $([bool]$WSL)
Set-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_SetupType -Value $global:SetupType_BuildOnlyEnv

# check memory
if ( $MasterVMMemory -lt 2GB ) {
    Write-Log 'SmallSetup needs minimal 2GB main memory, you have passed a lower value!'
    throw 'Memory passed to low'
}
Write-Log "Using $([math]::round($MasterVMMemory/1GB, 2))GB of memory for master VM"

# check disk
if ( $MasterDiskSize -lt 20GB ) {
    Write-Log 'SmallSetup needs minimal 20GB disk space, you have passed a lower value!'
    throw 'Disk size passed to low'
}
Write-Log "Using $([math]::round($MasterDiskSize/1GB, 2))GB of disk space for master VM"

$installationStageProxy = $Proxy
$operationStageProxy = 'http://' + $global:IP_NextHop + ':8181'
Write-Log 'Using the following proxies: '
Write-Log "  - installation stage: '$installationStageProxy'"
Write-Log "  - operation stage: '$operationStageProxy'"

&"$global:KubernetesPath\smallsetup\windowsnode\DeployWindowsNodeArtifacts.ps1" -KubernetesVersion $global:KubernetesVersion -Proxy $installationStageProxy -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation -ForceOnlineInstallation $ForceOnlineInstallation -SetupType $global:SetupType_BuildOnlyEnv
&"$global:KubernetesPath\smallsetup\windowsnode\publisher\PublishNssm.ps1"

&"$global:KubernetesPath\smallsetup\windowsnode\publisher\PublishPuttytools.ps1"

Write-Log 'Installing httpproxy daemon on Windows' -Console
&"$global:KubernetesPath\smallsetup\windowsnode\InstallHttpProxy.ps1" -Proxy $installationStageProxy

Write-Log 'Installing docker daemon on Windows' -Console
&"$global:KubernetesPath\smallsetup\windowsnode\publisher\PublishDocker.ps1"
&"$global:KubernetesPath\smallsetup\windowsnode\InstallDockerWin10.ps1" -AutoStart:$autoStartDockerd -Proxy "$installationStageProxy"

Write-Log 'Installing containerd daemon on Windows' -Console
&"$global:KubernetesPath\smallsetup\windowsnode\InstallContainerd.ps1" -Proxy "$installationStageProxy"
if (Test-Path($global:DownloadsDirectory)) {
    Remove-Item $global:DownloadsDirectory -Force -Recurse
}
if (Test-Path($global:WindowsNodeArtifactsDirectory)) {
    Remove-Item $global:WindowsNodeArtifactsDirectory -Force -Recurse
}

Write-Log 'Using NAT in dev only environment'
New-NetNat -Name $global:NetNatName -InternalIPInterfaceAddressPrefix $global:IP_CIDR | Out-Null

if (!$WSL) {
    Write-Log "Installing $global:VMName VM" -Console
    Write-Log "VM '$global:VMName' is not yet available, creating VM for build purposes..."
} else {
    Write-Log "Installing $global:VMName Distro" -Console
}

& "$global:KubernetesPath\smallsetup\kubemaster\InstallKubeMaster.ps1" -MemoryStartupBytes $MasterVMMemory -MasterVMProcessorCount $MasterVMProcessorCount -MasterDiskSize $MasterDiskSize -InstallationStageProxy $InstallationStageProxy -OperationStageProxy $operationStageProxy -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation -ForceOnlineInstallation $ForceOnlineInstallation -WSL:$WSL

Write-Log '---------------------------------------------------------------'
Write-Log "Build-only setup finished.   Total duration: $('{0:hh\:mm\:ss}' -f $installStopwatch.Elapsed )"
Write-Log '---------------------------------------------------------------'

Write-RefreshEnvVariables