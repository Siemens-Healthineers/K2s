# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Assists with preparing a Windows VM prior to calling kubeadm join

.DESCRIPTION
This script assists with joining a Windows node to a cluster.
- Downloads Kubernetes binaries (kubelet, kubeadm, flannel) at the version specified
- Registers kubelet as an nssm service. More info on nssm: https://nssm.cc/

.PARAMETER KubernetesVersion
Kubernetes version to download and use

.EXAMPLE
PS> .\SetupNode.ps1 -KubernetesVersion v1.19.2 -MasterIp 10.81.76.101 -MinSetup $true -HostGW $true

PS> .\SetupNode.ps1 -KubernetesVersion v1.20.4 -MasterIp 10.81.76.18 -MinSetup $false -Proxy http://your-proxy.example.com:8888 -HostGW $true
#>

Param(
    [parameter(Mandatory = $true, HelpMessage = 'Kubernetes version to use')]
    [string] $KubernetesVersion,
    [parameter(Mandatory = $true, HelpMessage = 'Master node ip address')]
    [string] $MasterIp,
    [parameter(Mandatory = $true, HelpMessage = 'Min setup as host only: true, false for normal node in medium/high kubernetes cluster')]
    [bool] $MinSetup,
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy = '',
    [parameter(Mandatory = $true, HelpMessage = 'Host-GW or VXLAN, Host-GW: true, false for vxlan')]
    [bool] $HostGW
)

# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1

# import global functions
. $PSScriptRoot\..\common\GlobalFunctions.ps1

$ErrorActionPreference = 'Stop'

if (!$KubernetesVersion.StartsWith('v')) {
    $KubernetesVersion = 'v' + $KubernetesVersion
}
Write-Log "Using Kubernetes version: $KubernetesVersion"

mkdir -force "$global:KubernetesPath" | Out-Null
Set-EnvVars

if (!($MinSetup)) {
    [Environment]::SetEnvironmentVariable('KUBECONFIG', "$global:KubernetesPath\config", [System.EnvironmentVariableTarget]::Machine)
}

$previousKubernetesVersion = Get-InstalledKubernetesVersion
Write-Log("Previous K8s version: $previousKubernetesVersion, current K8s version to install: $KubernetesVersion")

Set-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_K8sVersion -Value $KubernetesVersion
Set-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_InstallFolder -Value $global:KubernetesPath
Set-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_ProductVersion -Value $global:ProductVersion

if (!(Test-Path "$global:ExecutableFolderPath\")) {
    New-Item -ItemType 'directory' -Path "$global:ExecutableFolderPath" | Out-Null
}

mkdir -force "$($global:SystemDriveLetter):\var\log\kubelet" | Out-Null
mkdir -force "$($global:SystemDriveLetter):\var\log\kubeproxy" | Out-Null
mkdir -force "$global:KubeletConfigDir\etc\kubernetes" | Out-Null
mkdir -force "$($global:SystemDriveLetter):\etc\kubernetes\pki" | Out-Null
mkdir -force "$($global:SystemDriveLetter):\etc\kubernetes\kubelet.conf.d" | Out-Null
mkdir -force "$global:KubeletConfigDir\etc" | Out-Null
mkdir -force "$global:KubeletConfigDir\etc\kubernetes" | Out-Null
mkdir -force "$global:KubeletConfigDir\etc\kubernetes\manifests" | Out-Null
mkdir -force "$global:KubeletConfigDir\var\lib\minikube" | Out-Null

if (!(Test-Path "$global:KubeletConfigDir\etc\kubernetes\pki")) {
    New-Item -path "$global:KubeletConfigDir\etc\kubernetes\pki" -type SymbolicLink -value "$($global:SystemDriveLetter):\etc\kubernetes\pki\" | Out-Null
}

if (!(Test-Path "$global:KubeletConfigDir\var\lib\minikube\certs")) {
    New-Item -path "$global:KubeletConfigDir\var\lib\minikube\certs" -type SymbolicLink -value "$($global:SystemDriveLetter):\etc\kubernetes\pki\" | Out-Null
}

# copy flannel files
Write-Log 'Copy flannel files to right directory'
mkdir -force "$($global:SystemDriveLetter):\etc\cni" | Out-Null
mkdir -force "$($global:SystemDriveLetter):\etc\cni\net.d" | Out-Null
mkdir -force "$($global:SystemDriveLetter):\etc\kube-flannel" | Out-Null
mkdir -force "$($global:SystemDriveLetter):\opt" | Out-Null
mkdir -force "$($global:SystemDriveLetter):\opt\cni" | Out-Null
mkdir -force "$($global:SystemDriveLetter):\opt\cni\bin" | Out-Null
mkdir -force "$($global:SystemDriveLetter):\run" | Out-Null
mkdir -force "$($global:SystemDriveLetter):\run\flannel" | Out-Null
mkdir -force "$($global:SystemDriveLetter):\var\log\flanneld" | Out-Null
mkdir -force "$($global:SystemDriveLetter):\var\lib" | Out-Null


& "$global:KubernetesPath\smallsetup\SetupNetworking.ps1" -MinSetup:$MinSetup -HostGW:$HostGW

Copy-Item -Path "$global:KubernetesPath\bin\cni\*" -Destination "$($global:SystemDriveLetter):\opt\cni\bin" -Recurse