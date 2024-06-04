# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

# GlobalVariables.ps1
#   set some global variables used in multiple scripts (avoid duplication of data)

$global:KubernetesPath = (Get-Item $PSScriptRoot).Parent.Parent.FullName
$global:InstallationDriveLetter = ($global:KubernetesPath).Split(':')[0]
# TODO: remove, when migrating to new PS modules code structure
# new modules should use <root>\k2sSetup\lib\modules\k2s\k2s.infra.module\path\path.module.psm1::Get-SystemDriveLetter function instead
$global:SystemDriveLetter = 'C'

if (! $(Test-Path $global:KubernetesPath)) {
    throw "Basic setup failed, script path not found: $global:KubernetesPath"
}

# Resolving paths from config file if path contains environment variables etc.
function Force-Resolve-Path {
    <#
    .SYNOPSIS
        Calls Resolve-Path but works for files that don't exist.
    #>
    param (
        [string] $FileName
    )

    $FileName = Resolve-Path $FileName -ErrorAction SilentlyContinue -ErrorVariable _frperror
    if (-not($FileName)) {
        $FileName = $_frperror[0].TargetObject
    }

    return $FileName
}

# Read cluster configuration json
$global:JsonConfigFile = "$global:KubernetesPath\cfg\config.json"
$clusterConfig = Get-Content $global:JsonConfigFile | Out-String | ConvertFrom-Json
$smallsetup = $clusterConfig.psobject.properties['smallsetup'].value

$callstack = Get-PSCallStack
if (((@($callstack.Command) -like 'Start*.ps1').Count -gt 0 -or (@($callstack.Command) -like 'Install*.ps1').Count -gt 0)) {
    $smallsetup.psobject.properties['vfprules-k2s'].value | ConvertTo-Json | Out-File "$global:KubernetesPath\bin\cni\vfprules.json" -Encoding ascii
}

$global:ProductName = 'K2s' # TODO: utilize all over the PS scripts
$global:ProductVersion = "$(Get-Content -Raw -Path "$global:KubernetesPath\VERSION")"
$global:VMName = 'KubeMaster'
$global:ControlPlaneNodeHostname = 'kubemaster'
$global:SwitchName = 'KubeSwitch'
$global:WSLSwitchName = 'WSL'
$global:NetNatName = 'VMsNAT'
$global:ControlPlaneNodeNetworkInterfaceName = 'eth0'
$global:HookDir = "$global:KubernetesPath\LocalHooks"
$global:BinPath = "$global:KubernetesPath\bin"
$global:ExecutableFolderPath = "$global:KubernetesPath\bin\exe"
$global:DockerDir = "$global:KubernetesPath\bin\docker"
$global:DockerExe = "$global:DockerDir\docker.exe"
$global:KubernetesVersion = 'v1.29.5'
$global:FlannelVersion = 'v0.17.0'
$global:CNIPluginVersion = 'v1.1.1'
$global:CNIFlannelVersion = 'v1.0.1'
$global:SshExe = "$global:BinPath\plink.exe"
$global:ScpExe = "$global:BinPath\pscp.exe"
$global:DevconExe = "$global:BinPath\devgon.exe"
$global:NerdctlExe = "$global:BinPath\nerdctl.exe"
$global:KubectlExe = "$global:ExecutableFolderPath\kubectl.exe"
$global:k2sExe = "$global:KubernetesPath\k2s.exe"
$shareDir = $smallsetup.psobject.properties['shareDir'].value
$global:ShareMountPointInVm = $shareDir.psobject.properties['master'].value
$global:ShareMountPoint = Force-Resolve-Path $shareDir.psobject.properties['windowsWorker'].value
$global:ShareDrive = Split-Path -Path $global:ShareMountPoint -Qualifier
$global:ShareSubdir = (Split-Path -Path $global:ShareMountPoint -NoQualifier).TrimStart('\')

# Add ExecutableFolderPath to current path at beginning, so we can get sure that our executables are used
# (And e.g. no old kubectl from another location)

if (($null -eq $env:Path) -or !$env:Path.StartsWith($global:ExecutableFolderPath)) {
    $env:Path = $global:ExecutableFolderPath + [IO.Path]::PathSeparator + $env:Path
}

# Host VM network
$global:IP_Master = $smallsetup.psobject.properties['masterIP'].value
$global:IP_NextHop = $smallsetup.psobject.properties['kubeSwitch'].value
$global:IP_CIDR = $smallsetup.psobject.properties['masterNetworkCIDR'].value
$global:RemoteUserName_Master = 'remote'
$global:Remote_Master = "$global:RemoteUserName_Master@$global:IP_Master"

# Password for Linux/Windows VMs during installation
$global:VMPwd = 'admin'

# key for accessing VMs over SSH
$configDir = $smallsetup.psobject.properties['configDir'].value

$global:SshConfigDir = Force-Resolve-Path $configDir.psobject.properties['ssh'].value
$global:keyFileName = 'id_rsa'
$global:LinuxVMKey = $global:SshConfigDir + "\kubemaster\$global:keyFileName"
$global:WindowsVMKey = $global:SshConfigDir + "\windowsvm\$global:keyFileName"

$global:KubeConfigDir = Force-Resolve-Path $configDir.psobject.properties['kube'].value
$global:KubeletConfigDir = $global:SystemDriveLetter + ':\var\lib\kubelet'
$global:DockerConfigDir = Force-Resolve-Path $configDir.psobject.properties['docker'].value

# NSSM for controlling services
$global:NssmInstallDirectoryLegacy = "$env:ProgramFiles\nssm"
$global:NssmInstallDirectory = "$global:KubernetesPath\bin"

# Cluster CIDR
$global:ClusterCIDR = $smallsetup.psobject.properties['podNetworkCIDR'].value
$global:ClusterCIDR_Master = $smallsetup.psobject.properties['podNetworkMasterCIDR'].value
$global:ClusterCIDR_Host = $smallsetup.psobject.properties['podNetworkWorkerCIDR'].value
$global:ClusterCIDR_Gateway = $smallsetup.psobject.properties['cbr0Gateway'].value
$global:ClusterCIDR_NextHop = $smallsetup.psobject.properties['cbr0'].value
$global:ClusterCIDR_Services = $smallsetup.psobject.properties['servicesCIDR'].value
$global:ClusterCIDR_ServicesLinux = $smallsetup.psobject.properties['servicesCIDRLinux'].value
$global:ClusterCIDR_ServicesWindows = $smallsetup.psobject.properties['servicesCIDRWindows'].value
$global:ClusterCIDR_NatExceptions = $smallsetup.psobject.properties['clusterCIDRNatExceptions'].value

# kube DNS
$global:KubeDnsServiceIP = $smallsetup.psobject.properties['kubeDnsServiceIP'].value

# Network interface Master
$global:NetworkInterfaceCni0IP_Master = $smallsetup.psobject.properties['masterNetworkInterfaceCni0IP'].value

$global:IP_LoopbackAdapter = $smallsetup.psobject.properties['loopback'].value
$global:Gateway_LoopbackAdapter = $smallsetup.psobject.properties['loopbackGateway'].value
$global:CIDR_LoopbackAdapter = $smallsetup.psobject.properties['loopbackAdapterCIDR'].value

# storage
$global:ConfiguredStorageLocalDriveLetter = $smallsetup.psobject.properties['storageLocalDriveLetter'].value

# Local HTTP Proxy
$global:HttpProxyPort = '8181'
$global:ProxyInboundFirewallRule = "HTTP Proxy Inbound Allow Port $global:HttpProxyPort"
$global:HttpProxy = "$global:IP_NextHop`:$global:HttpProxyPort"

# Host firewall rule
$global:KubeVMFirewallRuleName = 'KubeMaster VM'
$global:LegacyVMFirewallRuleName = 'Edgemaster VM' # still referenced in few setups, to be removed in subsequent releases.

$global:L2BridgeSwitchName = 'cbr0'

# global settings for multi-VM K8s setup
$multivm = $smallsetup.psobject.properties['multivm'].value
$global:MultiVMWindowsVMName = 'WinNode' # WARNING: VM name must not exceed a certain length, otherwise unattend.xml file parsing will fail!
$global:MultiVMWinNodeIP = $multivm.psobject.properties['multiVMK8sWindowsVMIP'].value
$global:MultiVMHostName = 'win.k8s.onehc.net'
$global:Admin_WinNode = "administrator@$global:MultiVMWinNodeIP"

# setup config file
$global:SetupJsonFile = "$global:KubeConfigDir\setup.json"
$global:KubernetesImagesJson = "$global:KubeConfigDir\kubernetes_images.json"
$global:WindowsTimezoneConfig = "$global:KubeConfigDir\windowsZones.xml"
$global:SetupType_k2s = 'k2s'
$global:SetupType_MultiVMK8s = 'MultiVMK8s'
$global:SetupType_BuildOnlyEnv = 'BuildOnlyEnv'
$global:ConfigKey_K8sVersion = 'KubernetesVersion'
$global:ConfigKey_SetupType = 'SetupType'
$global:ConfigKey_HostGw = 'HostGW'
$global:ConfigKey_LoggedInRegistry = 'LoggedInRegistry'
$global:ConfigKey_WSL = 'WSL'
$global:ConfigKey_LinuxOnly = 'LinuxOnly'
$global:ConfigKey_UsedStorageLocalDriveLetter = 'UsedStorageLocalDriveLetter'
$global:ConfigKey_InstallFolder = 'InstallFolder'
$global:ConfigKey_ProductVersion = 'Version'
$global:ConfigKey_ControlPlaneNodeHostname = 'ControlPlaneNodeHostname'

$global:ConfigKey_LinuxOsType = 'LinuxOs'
$global:LinuxOsType_DebianCloud = 'DebianCloud'
$global:LinuxOsType_Ubuntu = 'Ubuntu'

$global:ConfigKey_ReuseExistingLinuxComputerForMasterNode = 'ReuseExistingLinuxComputerForMasterNode'

$global:LoopbackAdapter = 'Loopbackk2s'

# windows host join
$global:JoinConfigurationFilePath = "$global:KubernetesPath\smallsetup\common\JoinWindowsHost.yaml"

# image export
$global:ExportedImagesTempFolder = "$global:KubernetesPath\Temp\ExportedImages"
$global:CtrExe = "$global:KubernetesPath\bin\containerd\ctr.exe"

# logging
$global:k2sLogFilePart = ':\var\log\k2s.log'
$global:k2sLogFile = $global:SystemDriveLetter + $global:k2sLogFilePart

# provisioned base image
$global:SourcesDirectory = "$global:KubernetesPath"
$global:BinDirectory = "$global:SourcesDirectory\bin"
$global:KubemasterBaseImageName = 'Kubemaster-Base.vhdx'
$global:KubemasterBaseUbuntuImageName = 'Kubemaster-Base-Ubuntu.vhdx'
$global:KubemasterRootfsName = 'Kubemaster-Base.rootfs.tar.gz'
$global:KubemasterUbuntuRootfsName = 'Kubemaster-Base-Ubuntu.rootfs.tar.gz'
$global:ProvisioningTargetDirectory = "$global:BinDirectory\provisioning"

# download
$global:DownloadsDirectory = "$global:BinDirectory\downloads"

# windows node artifacts
$global:WindowsNodeArtifactsDownloadsDirectory = "$global:DownloadsDirectory\windowsnode"
$global:WindowsNodeArtifactsDirectory = "$global:BinDirectory\windowsnode"

# windows node artifacts zip file
$global:WindowsNodeArtifactsZipFileName = 'WindowsNodeArtifacts.zip'
$global:WindowsNodeArtifactsZipFilePath = "$global:BinPath\$global:WindowsNodeArtifactsZipFileName"