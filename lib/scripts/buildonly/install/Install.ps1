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

$infraModule = "$PSScriptRoot/../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"


$KubernetesVersion = Get-DefaultK8sVersion

$script:SetupType = 'BuildOnlyEnv'

Import-Module $infraModule, $nodeModule
Initialize-Logging -ShowLogs:$ShowLogs
Reset-LogFile -AppendLogFile:$AppendLogFile

$installStopwatch = [system.diagnostics.stopwatch]::StartNew()

Write-Log 'Installing Build Only Environment'
Set-EnvVars

$ErrorActionPreference = 'Continue'


Set-EnvVars

Add-k2sToDefenderExclusion
Stop-InstallIfDockerDesktopIsRunning

Enable-MissingWindowsFeatures $([bool]$WSL)

Set-ConfigSetupType -Value $script:SetupType
Set-ConfigWslFlag -Value $([bool]$WSL)

$productVersion = Get-ProductVersion
$kubePath = Get-KubePath

Set-ConfigInstallFolder -Value $kubePath
Set-ConfigProductVersion -Value $productVersion

if ($WSL) {
    Write-Log 'vEthernet (WSL) switch will be reconfigured! Your existing WSL distros will not work properly until you stop the cluster.'
    Write-Log 'Configuring WSL2'
    Set-WSL
}


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

Initialize-WinNode -KubernetesVersion $KubernetesVersion `
    -Proxy:"$Proxy" `
    -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation `
    -ForceOnlineInstallation $ForceOnlineInstallation `
    -SkipClusterSetup:$true

Write-Log 'Using NAT in dev only environment'
New-DefaultNetNat

Initialize-LinuxNode -VMStartUpMemory $MasterVMMemory `
    -VMProcessorCount $MasterVMProcessorCount `
    -VMDiskSize $MasterDiskSize `
    -InstallationStageProxy $Proxy `
    -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation `
    -ForceOnlineInstallation $ForceOnlineInstallation `
    -WSL:$WSL

Write-Log '---------------------------------------------------------------'
Write-Log "Build-only setup finished.   Total duration: $('{0:hh\:mm\:ss}' -f $installStopwatch.Elapsed )"
Write-Log '---------------------------------------------------------------'

Write-RefreshEnvVariables