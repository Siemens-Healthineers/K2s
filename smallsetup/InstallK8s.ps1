# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Assists with preparing a Windows system to be used for a mixed Linux/Windows Kubernetes cluster
This script is only valid for the K2s Setup!!!

.DESCRIPTION
This script assists in the following actions for K2s:
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

$installStopwatch = [system.diagnostics.stopwatch]::StartNew()

$infraModule =   "$PSScriptRoot\..\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule =    "$PSScriptRoot\..\lib\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
$temporaryIsolatedGlobalFunctionsModule = "$PSScriptRoot\ps-modules\only-while-refactoring\installation\still-to-merge.isolatedglobalfunctions.module.psm1"
$temporaryIsolatedCalledScriptsModule = "$PSScriptRoot\ps-modules\only-while-refactoring\installation\still-to-merge.isolatedcalledscripts.module.psm1"

Import-Module $infraModule, $nodeModule, $clusterModule, $temporaryIsolatedGlobalFunctionsModule, $temporaryIsolatedCalledScriptsModule


Initialize-Logging -ShowLogs:$ShowLogs
Reset-LogFile -AppendLogFile:$AppendLogFile
Set-LoggingPreferencesIntoScriptsIsolationModule -ShowLogs:$ShowLogs -AppendLogFile:$false

$ErrorActionPreference = 'Continue'

Write-Log 'Prerequisites checks before installation' -Console

Test-PathPrerequisites
Test-ControlPlanePrerequisites -MasterVMProcessorCount $MasterVMProcessorCount -MasterVMMemory $MasterVMMemory -MasterDiskSize $MasterDiskSize
Test-WindowsPrerequisites -WSL:$WSL
Stop-InstallationIfRequiredCurlVersionNotInstalled

Stop-InstallIfNoMandatoryServiceIsRunning

if ($CheckOnly) {
    Write-Log 'Early exit (CheckOnly)'
    exit
}

Write-Log 'Starting installation...'

# Add K2s executables as part of environment variable
Set-EnvVars

$Proxy = Get-OrUpdateProxyServer -Proxy:$Proxy

################################ SCRIPT START ###############################################

# make sure we are at the right place for install
$installationPath = Get-KubePath
Set-Location $installationPath

# set defaults for unset arguments
$KubernetesVersion = Get-DefaultK8sVersion
$script:SetupType = 'k2s'

$controlPlaneVmName = 'KubeMaster'

Set-ConfigWslFlag -Value $([bool]$WSL)
Set-ConfigSetupType -Value $script:SetupType

Write-Error "this is a test error"
exit


$linuxOsType = Get-LinuxOsType $LinuxVhdxPath
Set-ConfigLinuxOsType -Value $linuxOsType

Write-Log 'Setting up Windows worker node' -Console

# Install loopback adapter for l2bridge
New-DefaultLoopbackAdater

Set-InstallationPathIntoScriptsIsolationModule -Value $installationPath

Initialize-WinNode -KubernetesVersion $KubernetesVersion `
    -HostGW:$HostGW `
    -Proxy:"$Proxy" `
    -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation `
    -ForceOnlineInstallation $ForceOnlineInstallation

if ($WSL) {
    Write-Log "Setting up $controlPlaneVmName Distro" -Console
}
else {
    Write-Log "Setting up $controlPlaneVmName VM" -Console
}

# create the linux master
$ProgressPreference = 'SilentlyContinue'

$reuseExistingLinuxComputer = !([string]::IsNullOrWhiteSpace($LinuxVMIP))
$setupJsonFile = Get-SetupConfigFilePath
Set-ConfigValue -Path $setupJsonFile -Key 'ReuseExistingLinuxComputerForMasterNode' -Value $reuseExistingLinuxComputer
if ($reuseExistingLinuxComputer) {
    Write-Log "Configuring computer with IP '$LinuxVMIP' to act as Master Node"
    Invoke-Script_ExistingUbuntuComputerAsMasterNodeInstaller -IpAddress $LinuxVMIP -UserName $LinuxVMUsername -UserPwd $LinuxVMUserPwd -Proxy $Proxy
    Write-Log "Finished configuring computer with IP '$LinuxVMIP' to act as Master Node"

    Wait-ForSSHConnectionToLinuxVMViaSshKey
}
else {
    $vm = Get-Vm -Name $controlPlaneVmName -ErrorAction SilentlyContinue
    if ( !($vm) ) {
        # use the local httpproxy for the linux master VM
        $transparentproxy = 'http://' + $(Get-ConfiguredKubeSwitchIP) + ':8181'
        Write-Log "Local httpproxy proxy was set and will be used for linux VM: $transparentproxy"
        Install-AndInitKubemaster -VMStartUpMemory $MasterVMMemory -VMProcessorCount $MasterVMProcessorCount -VMDiskSize $MasterDiskSize -InstallationStageProxy $Proxy -OperationStageProxy $transparentproxy -HostGW $HostGW -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation -ForceOnlineInstallation $ForceOnlineInstallation -WSL:$WSL -LinuxVhdxPath $LinuxVhdxPath -LinuxUserName $LinuxVMUsername -LinuxUserPwd $LinuxVMUserPwd
    }
    Write-Log 'VM is now available'
}

# JOIN NODES
Write-Log "Preparing Kubernetes $KubernetesVersion by joining nodes" -Console

Initialize-KubernetesCluster -AdditionalHooksDir $AdditionalHooksDir


if (! $SkipStart) {
    Write-Log 'Starting Kubernetes System'
    Invoke-Script_StartK8s -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs

    if ($RestartAfterInstallCount -gt 0) {
        $restartCount = 0;
    
        while ($true) {
            $restartCount++
            Write-Log "Restarting Kubernetes System (iteration #$restartCount):"
    
            Invoke-Script_StopK8s -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs
            Start-Sleep 10 # Wait for renew of IP
    
            Invoke-Script_StartK8s -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs
            Start-Sleep -s 5
    
            if ($restartCount -eq $RestartAfterInstallCount) {
                Write-Log 'Restarting Kubernetes System Completed'
                break;
            }
        }
    }

    # show results
    Write-Log "Current state of kubernetes nodes:`n"
    Start-Sleep 2
    &$kubectlExe get nodes -o wide
} else {
    Invoke-Script_StopK8s -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs
}

Invoke-Hook -HookName 'AfterBaseInstall' -AdditionalHooksDir $AdditionalHooksDir

Write-Log '---------------------------------------------------------------'
Write-Log "K2s setup finished.   Total duration: $('{0:hh\:mm\:ss}' -f $installStopwatch.Elapsed )"
Write-Log '---------------------------------------------------------------'

Write-RefreshEnvVariables

