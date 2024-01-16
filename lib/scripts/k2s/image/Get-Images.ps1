# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

# Images.ps1

<#
.Description

#>

#Requires -RunAsAdministrator

<#
.SYNOPSIS
List all container images present in K2s

.DESCRIPTION
List all container images present in K2s

.PARAMETER IncludeK8sImages
If set to true, will list k8s images as well

.PARAMETER EncodeStructuredOutput
If set to true, will encode and send result as structured data to the CLI

.EXAMPLE
# Outputs all container images present in K2s
PS> .\Get-Images.ps1

.EXAMPLE
# Outputs all container images present in K2s including K8s images and will encode and send result as structured data to the CLI
PS> .\Get-Images.ps1 -IncludeK8sImages -EncodeStructuredOutput
#>

Param (
    [parameter(Mandatory = $false)]
    [switch] $IncludeK8sImages,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput
)

$infraModule = "$PSScriptRoot/../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
Import-Module $infraModule, $clusterModule

Test-ClusterAvailability

class StoredImages {
    [System.Collections.ArrayList]$ContainerImages
    [String]$ContainerRegistry
    [System.Collections.ArrayList]$PushedImages
}

$StoredImages = [StoredImages]::new()
$StoredImages.ContainerImages = @(Get-ContainerImagesInk2s -IncludeK8sImages $IncludeK8sImages)

$StoredImages.ContainerRegistry = $(Get-RegistriesFromSetupJson) | Where-Object { $_ -match 'k2s-registry.*' }
$StoredImages.PushedImages = @(Get-PushedContainerImages)

if ($EncodeStructuredOutput) {
    Send-ToCli -MessageType 'StoredImages' -Message $StoredImages
}
else {
    Write-Host ($StoredImages.ContainerImages | Format-Table | Out-String).Trim()
    Write-Host ''
    Write-Host "Pushed container images -> $StoredImages.ContainerRegistry"
    Write-Host ($StoredImages.PushedImages | Format-Table | Out-String).Trim() 
}