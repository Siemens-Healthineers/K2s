# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

# ListImages.ps1

<#
.Description
List all container images present in k2s
#>

Param (
    [parameter(Mandatory = $false)]
    [switch] $IncludeK8sImages,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput
)

# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\..\common\GlobalFunctions.ps1

Import-Module $PSScriptRoot\ImageFunctions.module.psm1 -DisableNameChecking

Test-ClusterAvailabilityForImageFunctions

$registryFunctionsModule = "$PSScriptRoot\RegistryFunctions.module.psm1"
$cliMessagesModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/cli-messages/cli-messages.module.psm1"
Import-Module $registryFunctionsModule -DisableNameChecking
Import-Module $cliMessagesModule -DisableNameChecking

Class StoredImages {
    [System.Collections.ArrayList]$ContainerImages
    [String]$ContainerRegistry
    [System.Collections.ArrayList]$PushedImages
}

$StoredImages = [StoredImages]::new()
$StoredImages.ContainerImages = @(Get-ContainerImagesInk2s -IncludeK8sImages $IncludeK8sImages)

$StoredImages.ContainerRegistry = $(Get-RegistriesFromSetupJson) | Where-Object {$_ -match "k2s-registry.*"}
$StoredImages.PushedImages = @(Get-PushedContainerImages)

if ($EncodeStructuredOutput) {
    Send-ToCli -MessageType 'StoredImages' -Message $StoredImages
} else {
    Write-Host ($StoredImages.ContainerImages | Format-Table | Out-String).Trim()
    Write-Host ""
    Write-Host "Pushed container images -> $StoredImages.ContainerRegistry"
    Write-Host ($StoredImages.PushedImages | Format-Table | Out-String).Trim()
}