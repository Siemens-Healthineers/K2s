# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

$pathModule = "$PSScriptRoot\..\..\k2s.infra.module\path\path.module.psm1"
Import-Module $pathModule

# Read cluster configuration json
$kubePath = Get-KubePath
$controlPlaneSwitchName = 'KubeSwitch'
$configFile = "$kubePath\cfg\config.json"
$rootConfig = Get-Content $configFile | Out-String | ConvertFrom-Json
$smallsetup = $rootConfig.psobject.properties['smallsetup'].value

function Expand-Path {
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

$configDir = $rootConfig.psobject.properties['configDir'].value
$configuredStorageLocalDriveLetter = $smallsetup.psobject.properties['storageLocalDriveLetter'].value
$configuredstorageLocalDriveFolder = $smallsetup.psobject.properties['storageLocalDriveFolder'].value

$kubeConfigDir = Expand-Path $configDir.psobject.properties['kube'].value
$sshConfigDir = Expand-Path $configDir.psobject.properties['ssh'].value
$dockerConfigDir = Expand-Path $configDir.psobject.properties['docker'].value
$k2sConfigDir = Expand-Path $configDir.psobject.properties['k2s'].value

$sshKeyFileName = 'id_rsa'
$kubernetesImagesJsonFile = "$k2sConfigDir\kubernetes_images.json"
$sshKeyControlPlane = "$sshConfigDir\k2s\$sshKeyFileName"

#NETWORKING
$ipControlPlane = $smallsetup.psobject.properties['masterIP'].value
$ipNextHop = $smallsetup.psobject.properties['kubeSwitch'].value
$ipControlPlaneCIDR = $smallsetup.psobject.properties['masterNetworkCIDR'].value

# Cluster CIDR
$clusterCIDR = $smallsetup.psobject.properties['podNetworkCIDR'].value
$clusterCIDRServices = $smallsetup.psobject.properties['servicesCIDR'].value

# DNS service IP address
$kubeDnsServiceIP = $smallsetup.psobject.properties['kubeDnsServiceIP'].value

# Master network cni interface IP address
$masterNetworkInterfaceCni0IP = $smallsetup.psobject.properties['masterNetworkInterfaceCni0IP'].value

$legacyClusterName = 'kubernetes'
$clusterName = $rootConfig.psobject.properties['clusterName'].value

#CONSTANTS
New-Variable -Name 'SetupJsonFile' -Value "$k2sConfigDir\setup.json" -Option Constant


# PUBLIC FUNCTIONS

function Get-RootConfig {
    return $rootConfig
}

function Get-SshConfigDir {
    return $sshConfigDir
}

function Get-ConfiguredKubeConfigDir {
    return $kubeConfigDir
}

function Get-KubernetesImagesFilePath {
    return $kubernetesImagesJsonFile
}

function Get-k2sConfigFilePath {
    return $configFile
}

function Get-K2sConfigDir {
    return $k2sConfigDir
}

function Get-SetupConfigFilePath {
    return $SetupJsonFile
}

function Get-ProductVersion {
    return "$(Get-Content -Raw -Path "$kubePath\VERSION")"
}

function Get-SSHKeyControlPlane {
    return $sshKeyControlPlane
}

function Get-SSHKeyFileName {
    return $sshKeyFileName
}

function Get-ConfiguredIPControlPlane {
    return $ipControlPlane
}

function Get-RootConfigk2s {
    return $smallsetup
}

function Get-ConfiguredStorageLocalDriveLetter {
    return $configuredStorageLocalDriveLetter
}

function Get-ConfiguredstorageLocalDriveFolder {
    return $configuredstorageLocalDriveFolder
}

function Get-ConfiguredDockerConfigDir {
    return $dockerConfigDir
}

function Get-ConfiguredClusterCIDR {
    return $clusterCIDR
}

function Get-ConfiguredClusterCIDRServices {
    return $clusterCIDRServices
}

function Get-ConfiguredKubeDnsServiceIP {
    return $kubeDnsServiceIP
}

function Get-ConfiguredMasterNetworkInterfaceCni0IP {
    return $masterNetworkInterfaceCni0IP
}

function Get-ConfiguredKubeSwitchIP {
    return $ipNextHop
}

function Get-ConfiguredControlPlaneCIDR {
    return $ipControlPlaneCIDR
}

function Get-ControlPlaneNodeDefaultSwitchName {
    return $controlPlaneSwitchName
}

function Get-DefaultTempPwd {
    return 'admin'
}

function Get-ConfiguredClusterNetworkPrefix {
    return $ipControlPlaneCIDR.Substring($ipControlPlaneCIDR.IndexOf('/') + 1)
}

function Get-ClusterName {
    return $clusterName
}

<#
.SYNOPSIS
    Creates a specified directory if not existing.
.DESCRIPTION
    Creates a specified directory if not existing.
.EXAMPLE
    New-DirectoryIfNotExisting -Path 'c:\temp-dir'
    New-DirectoryIfNotExisting 'c:\temp-dir'
    'c:\temp-dir' | New-DirectoryIfNotExisting
.PARAMETER Path
    Directory path
.NOTES
    Function supports pipelines ('Path')
#>
function New-DirectoryIfNotExisting {
    param (
        [Parameter(ValueFromPipeline)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    if (!(Test-Path $Path)) {
        Write-Log "Directory '$Path' not existing, creating it ..."

        New-Item -Path $Path -ItemType Directory | Out-Null

        Write-Log "Directory '$Path' created."
    }
    else {
        Write-Log "Directory '$Path' already existing."
    }
}


<#
.SYNOPSIS
    Retrieves the specified config value from a given JSON file.
.DESCRIPTION
    Retrieves the specified config value from a given JSON file.
.EXAMPLE
    $version = Get-ConfigValue -Path "config.json" -Key 'version'
.PARAMETER Path
    Path to config JSON file
.PARAMETER Key
    Property key
.OUTPUTS
    The property value if existing; otherwise null
.NOTES
    Config file must contain valid JSON.
    Only top-level properties are read.
    If the property exists with null value, null will be returned (same as if the property did not exist).
    If the config file does not exist, null will be returned.
#>
function Get-ConfigValue {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Path = $(throw 'Please provide the config file path.'),
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Key = $(throw 'Please provide the config key.')
    )

    if (!(Test-Path $Path)) {
        return $null
    }

    return $(Get-Content $Path -Raw | ConvertFrom-Json).$Key
}

<#
.SYNOPSIS
    Writes a key-value pair to a given JSON file.
.DESCRIPTION
    Writes a key-value pair to a given JSON file.
.EXAMPLE
    Set-ConfigValue -Path "config.json" -Key 'version' -Value '123'
.PARAMETER Path
    Path to config JSON file
.PARAMETER Key
    Property key
.PARAMETER Value
    Property value
.NOTES
    Config file must contain valid JSON.
    Only top-level properties are set.
    Existing properties with the same key get overwritten.
    If the config file does not exist, it will be created.
#>
function Set-ConfigValue {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Path = $(throw 'Please provide the config file path.'),
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Key = $(throw 'Please provide the config key.'),
        [Parameter()]
        [object] $Value = $(throw 'Please provide the config value.')
    )

    if (Test-Path $Path) {
        $json = $(Get-Content $Path -Raw | ConvertFrom-Json)
    }
    else {
        Split-Path -parent $Path | New-DirectoryIfNotExisting

        $json = @{ }
    }

    $json | Add-Member -Name $Key -Value $Value -MemberType NoteProperty -Force

    $json | ConvertTo-Json -Depth 32 | Set-Content -Force $Path # default object depth appears to be 2
}

<#
.SYNOPSIS
    Returns the installed K8s version if present.
.DESCRIPTION
    Returns the installed K8s version if present.
.EXAMPLE
    $version = Get-ConfigInstalledKubernetesVersion
.OUTPUTS
    The installed K8s version if present; otherwise 'unknown'
.NOTES
    Checks the local setup json file for the K8s version
#>
function Get-ConfigInstalledKubernetesVersion {
    $k8sVersion = Get-ConfigValue -Path $SetupJsonFile -Key 'KubernetesVersion'

    if ($k8sVersion) {
        return $k8sVersion
    }

    return 'unknown'
}

function Set-ConfigInstalledKubernetesVersion {
    param (
        [object] $Value = $(throw 'Please provide the config value.')
    )
    Set-ConfigValue -Path $SetupJsonFile -Key 'KubernetesVersion' -Value $Value
}

function Get-ConfigInstallFolder {
    return Get-ConfigValue -Path $SetupJsonFile -Key 'InstallFolder'
}

function Set-ConfigInstallFolder {
    param (
        [object] $Value = $(throw 'Please provide the config value.')
    )
    Set-ConfigValue -Path $SetupJsonFile -Key 'InstallFolder' -Value $Value
}

function Get-ConfigProductVersion {
    return Get-ConfigValue -Path $SetupJsonFile -Key 'Version'
}

function Set-ConfigProductVersion {
    param (
        [object] $Value = $(throw 'Please provide the config value.')
    )
    Set-ConfigValue -Path $SetupJsonFile -Key 'Version' -Value $Value
}

function Get-ConfigUsedStorageLocalDriveLetter {
    return Get-ConfigValue -Path $SetupJsonFile -Key 'UsedStorageLocalDriveLetter'
}

function Get-ConfigSetupType {
    return Get-ConfigValue -Path $SetupJsonFile -Key 'SetupType'
}

function Set-ConfigSetupType {
    param (
        [object] $Value = $(throw 'Please provide the config value.')
    )
    Set-ConfigValue -Path $SetupJsonFile -Key 'SetupType' -Value $Value
}

function Get-ConfigWslFlag {
    $wslValue = Get-ConfigValue -Path $SetupJsonFile -Key 'WSL'
    if ($null -eq $wslValue) {
        return $false
    }
    return $wslValue
}

function Set-ConfigWslFlag {
    param (
        [object] $Value = $(throw 'Please provide the config value.')
    )
    Set-ConfigValue -Path $SetupJsonFile -Key 'WSL' -Value $Value
}


# Windows container image build is enabled or disabled. If enabled docker is installed.
function Get-ConfigWinBuildEnabledFlag {
    return Get-ConfigValue -Path $SetupJsonFile -Key 'WinBuildEnabled'
}

function Set-ConfigWinBuildEnabledFlag {
    param (
        [object] $Value = $(throw 'Please provide the config value.')
    )
    Set-ConfigValue -Path $SetupJsonFile -Key 'WinBuildEnabled' -Value $Value
}


function Get-ConfigLinuxOnly {
    return Get-ConfigValue -Path $SetupJsonFile -Key 'LinuxOnly'
}

function Set-ConfigLinuxOnly {
    param (
        [object] $Value = $(throw 'Please provide the config value.')
    )
    Set-ConfigValue -Path $SetupJsonFile -Key 'LinuxOnly' -Value $Value
}

function Set-ConfigUsedStorageLocalDriveLetter {
    param (
        [object] $Value = $(throw 'Please provide the config value.')
    )
    Set-ConfigValue -Path $SetupJsonFile -Key 'UsedStorageLocalDriveLetter' -Value $Value
}

function Get-ConfigHostGW {
    return Get-ConfigValue -Path $SetupJsonFile -Key 'HostGW'
}

function Set-ConfigHostGW {
    param (
        [object] $Value = $(throw 'Please provide the config value.')
    )
    Set-ConfigValue -Path $SetupJsonFile -Key 'HostGW' -Value $Value
}

function Get-ConfigControlPlaneNodeHostname () {
    $hostname = Get-ConfigValue -Path $SetupJsonFile -Key 'ControlPlaneNodeHostname'

    if ($hostname) {
        return $hostname
    }

    return 'kubemaster'
}

function Set-ConfigControlPlaneNodeHostname($hostname) {
    Set-ConfigValue -Path $SetupJsonFile -Key 'ControlPlaneNodeHostname' -Value $hostname
    Write-Log "Saved VM hostname '$hostname' in file '$SetupJsonFile'"
}

function Get-ConfigVMNodeHostname () {
    $hostname = Get-ConfigValue -Path $SetupJsonFile -Key 'VMNodeHostname'

    if ($hostname) {
        return $hostname
    }

    return 'winnode'
}

function Set-ConfigVMNodeHostname($hostname) {
    Set-ConfigValue -Path $SetupJsonFile -Key 'VMNodeHostname' -Value $hostname
    Write-Log "Saved VM hostname '$hostname' in file '$SetupJsonFile'"
}

function Get-DefaultRegistry {
    return Get-ConfigValue -Path $SetupJsonFile -Key 'defaultRegistry'
}

function Get-RegistryToken() {
    # Read the token from the file
    $token = Get-Content -Path "$kubePath\bin\registry.dat" -Raw
    return [string]$token
}

function Get-MinimalProvisioningBaseMemorySize {
    return 2GB
}
function Get-MinimalProvisioningBaseImageDiskSize {
    return 10GB
}
function Get-DefaultK8sVersion {
    return 'v1.35.0'
}

<#
.SYNOPSIS
Gets the configured proxy overrides for the user in windows. Proxy overrides are the hosts for which the requests must not
be forwarded to the proxy. Should be called only when Proxy is enabled.

.DESCRIPTION
When proxy settings are configured for the user in Windows, the proxy overrides are configured in the registry key
HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ProxyOverrides
#>
function Get-ProxyOverrideFromWindowsSettings {
    $reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    return $reg.ProxyOverride
}

function Get-LinuxLocalSharePath {
    return $linuxLocalSharePath
}

function Get-WindowsLocalSharePath {
    return $windowsLocalSharePath
}

function Get-MirrorRegistries {
    $rootConfig = Get-RootConfigk2s
    $mirrorRegistries = $rootConfig.psobject.properties['mirrorRegistries'].value
    return $mirrorRegistries
}

function Get-InstalledClusterName {
    $value = Get-ConfigValue -Path $SetupJsonFile -Key 'ClusterName'
    if ($value) {
        return $value
    }
    return $legacyClusterName
}

function Set-InstalledClusterName {
    param (
        [object] $Value = $(throw 'Please provide the config value.')
    )
    Set-ConfigValue -Path $SetupJsonFile -Key 'ClusterName' -Value $Value
}

Export-ModuleMember -Function Get-ConfigValue,
Set-ConfigValue,
Get-ConfiguredKubeConfigDir,
Get-k2sConfigFilePath,
Get-SetupConfigFilePath,
Get-K2sConfigDir,
Get-KubernetesImagesFilePath,
Get-ProductVersion,
Get-SSHKeyControlPlane,
Get-ConfiguredIPControlPlane,
Get-ConfigSetupType,
Get-ConfigUsedStorageLocalDriveLetter,
Get-ConfiguredStorageLocalDriveLetter,
Get-ConfiguredstorageLocalDriveFolder,
Get-ConfigInstalledKubernetesVersion,
Get-ConfiguredDockerConfigDir,
Get-ConfiguredClusterCIDR,
Get-ConfiguredKubeSwitchIP,
Get-ConfiguredControlPlaneCIDR,
Get-ConfiguredClusterCIDRServices,
Get-ConfiguredKubeDnsServiceIP,
Get-ConfiguredMasterNetworkInterfaceCni0IP,
Get-ConfigControlPlaneNodeHostname,
Get-SSHKeyFileName,
Set-ConfigSetupType,
Get-ConfigWslFlag,
Set-ConfigWslFlag,
Get-ConfigLinuxOnly,
Set-ConfigLinuxOnly,
Get-RootConfigk2s,
Set-ConfigUsedStorageLocalDriveLetter,
Set-ConfigInstalledKubernetesVersion,
Get-ConfigInstallFolder,
Set-ConfigInstallFolder,
Get-ConfigProductVersion,
Set-ConfigProductVersion,
Get-ConfigHostGW,
Set-ConfigHostGW,
Set-ConfigControlPlaneNodeHostname,
Get-ControlPlaneNodeDefaultSwitchName,
Get-ConfigVMNodeHostname,
Set-ConfigVMNodeHostname,
Get-DefaultRegistry,
Get-RegistryToken,
Get-SshConfigDir,
Get-MinimalProvisioningBaseImageDiskSize,
Get-MinimalProvisioningBaseMemorySize,
Get-RootConfig,
Get-DefaultTempPwd,
Get-DefaultK8sVersion,
Get-LinuxLocalSharePath,
Get-WindowsLocalSharePath,
Get-ConfigWinBuildEnabledFlag,
Set-ConfigWinBuildEnabledFlag,
Get-ConfiguredClusterNetworkPrefix,
Get-MirrorRegistries,
Get-ClusterName,
Get-InstalledClusterName,
Set-InstalledClusterName