# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

param (
    [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of VM')]
    [long]$VMMemoryStartupBytes,
    [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for VM')]
    [long]$VMProcessorCount,
    [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of VM')]
    [uint64]$VMDiskSize,
    [parameter(Mandatory = $false, HelpMessage = 'The HTTP proxy if available.')]
    [string]$Proxy = '',
    [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
    [ValidateScript({ Assert-Pattern -Path $_ -Pattern ".*\.vhdx$" })]
    [parameter(Mandatory = $false, HelpMessage = 'The path to save the provisioned base image.')]
    [string] $OutputPath = $(throw "Argument missing: OutputPath"),
    [parameter(Mandatory = $false, HelpMessage = 'Keep artifacts used on provisioning')]
    [switch] $KeepArtifactsUsedOnProvisioning = $false
    )

    Assert-Path -Path (Split-Path $OutputPath) -PathType "Container" -ShallExist $true | Out-Null

&"$PSScriptRoot\..\common\GlobalVariables.ps1"
# dot source common functions into script scope
. "$PSScriptRoot\..\common\GlobalFunctions.ps1"

$linuxNodeModule = "$global:KubernetesPath\smallsetup\linuxnode\linuxnode.module.psm1"
$linuxNodeDebianModule = "$global:KubernetesPath\smallsetup\linuxnode\debian\linuxnode.debian.module.psm1"
$provisioningModule = "$global:KubernetesPath\smallsetup\baseimage\provisioning.module.psm1"
Import-Module $linuxNodeModule,$linuxNodeDebianModule,$provisioningModule

New-KubeworkerBaseImage -VMMemoryStartupBytes $VMMemoryStartupBytes -VMProcessorCount $VMProcessorCount -VMDiskSize $VMDiskSize -Proxy $Proxy -OutputPath $OutputPath -KeepArtifactsUsedOnProvisioning $KeepArtifactsUsedOnProvisioning
