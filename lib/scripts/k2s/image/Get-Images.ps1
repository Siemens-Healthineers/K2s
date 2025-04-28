# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
List all container images present in K2s

.DESCRIPTION
List all container images present in K2s

.PARAMETER EncodeStructuredOutput
If set to true, will encode and send result as structured data to the CLI

.PARAMETER MessageType
Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true

.PARAMETER IncludeK8sImages
If set to true, will list K8s images as well

.EXAMPLE
# Outputs all container images present in K2s
PS> .\Get-Images.ps1

.EXAMPLE
# Outputs all container images present in K2s including K8s images and will encode and send result as structured data to the CLI
PS> .\Get-Images.ps1 -IncludeK8sImages -EncodeStructuredOutput -MessageType my-images
#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType,
    [parameter(Mandatory = $false)]
    [switch] $IncludeK8sImages
)
$infraModule = "$PSScriptRoot/../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"

Import-Module $infraModule, $clusterModule

Initialize-Logging

$script = $MyInvocation.MyCommand.Name

Write-Log "[$script] started with EncodeStructuredOutput='$EncodeStructuredOutput' and MessageType='$MessageType' and IncludeK8sImages='$IncludeK8sImages'"

try {
    $systemError = Test-SystemAvailability -Structured
    if ($systemError) {
        if ($EncodeStructuredOutput -eq $true) {
            Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
            return
        }
    
        Write-Log $systemError.Message -Error
        exit 1
    }

    $images = @{Error = $null }
    $images.ContainerImages = @(Get-ContainerImagesInk2s -IncludeK8sImages $IncludeK8sImages)
    $images.ContainerRegistry = $(Get-RegistriesFromSetupJson) | Where-Object { $_ -match 'k2s.registry.*' }
    $images.PushedImages = @(Get-PushedContainerImages)

    if ($EncodeStructuredOutput) {
        Send-ToCli -MessageType $MessageType -Message $images
    }
    else {
        $images
    }

    Write-Log "[$script] finished"
}
catch {
    Write-Log "[$script] $($_.Exception.Message) - $($_.ScriptStackTrace)" -Error

    throw $_
}