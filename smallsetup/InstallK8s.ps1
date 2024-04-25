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

$logModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.infra.module\log\log.module.psm1"
$proxyModule = "$PSScriptRoot\ps-modules\proxy\proxy.module.psm1"
$pathModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.infra.module\path\path.module.psm1"
$configModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.infra.module\config\config.module.psm1"
$vmModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.node.module\linuxnode\vm\vm.module.psm1"
$kubetoolsModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.node.module\windowsnode\downloader\artifacts\kube-tools\kube-tools.module.psm1"
$loopbackAdapterModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.node.module\windowsnode\network\loopbackadapter.module.psm1"
$systemModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.node.module\windowsnode\system\system.module.psm1"
$hooksModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.infra.module\hooks\hooks.module.psm1"
$temporaryIsolatedGlobalFunctionsModule = "$PSScriptRoot\ps-modules\only-while-refactoring\installation\still-to-merge.isolatedglobalfunctions.module.psm1"
$temporaryIsolatedCalledScriptsModule = "$PSScriptRoot\ps-modules\only-while-refactoring\installation\still-to-merge.isolatedcalledscripts.module.psm1"

Import-Module $logModule, $systemModule, $proxyModule, $pathModule, $configModule, $vmModule, $kubetoolsModule, $loopbackAdapterModule, $hooksModule, $temporaryIsolatedGlobalFunctionsModule, $temporaryIsolatedCalledScriptsModule

Initialize-Logging -ShowLogs:$ShowLogs

$ErrorActionPreference = 'Continue'
if ($Trace) {
    Set-PSDebug -Trace 1
}

$installStopwatch = [system.diagnostics.stopwatch]::StartNew()

#cleanup old logs
Reset-LogFile -AppendLogFile:$AppendLogFile

Set-LoggingPreferencesIntoScriptsIsolationModule -ShowLogs:$ShowLogs -AppendLogFile:$false

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

$Proxy = Get-OrUpdateProxyServer -Proxy:$Proxy

Add-K2sToDefenderExclusion

Stop-InstallIfDockerDesktopIsRunning

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

################################ SCRIPT START ###############################################

# make sure we are at the right place for install
$installationPath = Get-KubePath
Set-Location $installationPath

# set defaults for unset arguments
$KubernetesVersion = Get-DefaultK8sVersion
$script:SetupType = 'k2s'

# check prerequisites
Write-Log 'Running some health checks before installation...'

$installationDirectoryType = Get-Item "$installationPath" | Select-Object -ExpandProperty LinkType
if ($null -ne $installationDirectoryType) {
    throw "Your installation directory '$installationPath' is of type '$installationDirectoryType'. Only normal directories are supported."
}

$ReleaseId = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild
if ($ReleaseId -lt 17763) {
    Write-Log "SmallSetup needs minimal Windows Version 1809, you have $ReleaseId"
    throw "Windows release $ReleaseId not usable"
}

Stop-InstallationIfRequiredCurlVersionNotInstalled

Enable-MissingWindowsFeatures $([bool]$WSL)

Stop-InstallIfNoMandatoryServiceIsRunning

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

$controlPlaneVmName = 'KubeMaster'

if (Get-VM -ErrorAction SilentlyContinue -Name $controlPlaneVmName) {
    throw "$controlPlaneVmName VM must not exist when running the installer, do UninstallK8s.ps1 first"
}

if ($CheckOnly) {
    Write-Log 'Early exit (CheckOnly)'
    exit
}


Write-Log 'Starting installation...'

Set-ConfigWslFlag -Value $([bool]$WSL)

Set-ConfigSetupType -Value $script:SetupType

$linuxOsType = Get-LinuxOsType $LinuxVhdxPath
Set-ConfigLinuxOsType -Value $linuxOsType

Write-Log 'Setting up Windows worker node' -Console

# Install loopback adapter for l2bridge
New-DefaultLoopbackAdater

Set-InstallationPathIntoScriptsIsolationModule -Value $installationPath
Invoke-Script_DeployWindowsNodeArtifacts -KubernetesVersion $KubernetesVersion -Proxy "$Proxy" -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation -ForceOnlineInstallation $ForceOnlineInstallation -SetupType $script:SetupType

Invoke-Script_PublishNssm

if (!(Test-Path "$(Get-KubeBinPath)\docker\docker.exe") -or !(Get-Service docker -ErrorAction SilentlyContinue)) {
    $autoStartDockerd = !$UseContainerd
    Invoke-Script_PublishDocker
    Invoke-Script_InstallDockerWin10 -AutoStart:$autoStartDockerd -Proxy "$Proxy"
}

# setup host as a worker node (installs nssm for starting kubelet, flannel and kubeproxy)
$controlPlaneNodeIpAddress = Get-ConfiguredIPControlPlane
Invoke-Script_SetupNode -KubernetesVersion $KubernetesVersion -MasterIp $controlPlaneNodeIpAddress -MinSetup:$true -HostGW:$HostGW -Proxy:"$Proxy"

# install containerd
if ($UseContainerd) {
    Invoke-Script_InstallContainerd -Proxy "$Proxy"
    Invoke-Script_PublishWindowsImages
}

if (!$UseContainerd) {
    # restart docker because it hangs often
    if ($(Get-Service -Name kubelet -ErrorAction SilentlyContinue).Status -eq 'Running') {
        Stop-Service -Name kubelet
    }
    Restart-Service docker
}

# install K8s services
Invoke-Script_PublishKubetools
Invoke-Script_InstallKubelet -UseContainerd:$UseContainerd
Invoke-Script_PublishFlannel
Invoke-Script_InstallFlannel
Invoke-Script_InstallKubeProxy
Invoke-Script_PublishWindowsExporter
Invoke-Script_InstallWinExporter
Invoke-Script_InstallHttpProxy -Proxy $Proxy
Invoke-Script_PublishDnsProxy
Invoke-Script_InstallDnsProxy
Invoke-Script_PublishPuttytools


# remove folder with windows node artifacts since all of them are already published to the expected locations
$windowsNodeArtifactsDirectory = "$(Get-KubePath)\bin\windowsnode"
Remove-Item $windowsNodeArtifactsDirectory -Recurse -Force -ErrorAction SilentlyContinue

# reset some services
$binPath = Get-KubeBinPath
&"$binPath\nssm" set kubeproxy Start SERVICE_DEMAND_START | Out-Null
&"$binPath\nssm" set kubelet Start SERVICE_DEMAND_START | Out-Null
&"$binPath\nssm" set flanneld Start SERVICE_DEMAND_START | Out-Null

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

Write-Log 'Joining Nodes'

Copy-KubeConfigFromControlPlaneNode

# set context on windows host (add to existing contexts)
Invoke-Script_AddContextToConfig

Invoke-Hook -HookName 'AfterVmInitialized' -AdditionalHooksDir $AdditionalHooksDir

# try to join host windows node
Write-Log 'starting the join process'
Invoke-Script_JoinWindowsHost

# set new limits for the windows node for disk pressure
# kubelet is running now (caused by JoinWindowsHost.ps1), so we stop it. Will be restarted in StartK8s.ps1.
Stop-Service kubelet
$kubeletconfig = "$(Get-KubeletConfigDir)\config.yaml"
Write-Log "kubelet config: $kubeletconfig"
$content = Get-Content $kubeletconfig
$content | ForEach-Object { $_ -replace 'evictionPressureTransitionPeriod:',
    "evictionHard:`r`n  nodefs.available: 8Gi`r`n  imagefs.available: 8Gi`r`nevictionPressureTransitionPeriod:" } |
Set-Content $kubeletconfig

# add ip to hosts file
Invoke-Script_AddToHosts

# show results
Write-Log "Current state of kubernetes nodes:`n"
Start-Sleep 2
$kubectlExe = "$(Get-KubeToolsPath)\kubectl.exe"
&$kubectlExe get nodes -o wide

Write-Log "Collecting kubernetes images and storing them to $(Get-KubernetesImagesFilePath)."
$imageFunctionsModulePath = "$PSScriptRoot\helpers\ImageFunctions.module.psm1"
Import-Module $imageFunctionsModulePath -DisableNameChecking
Write-KubernetesImagesIntoJson

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

