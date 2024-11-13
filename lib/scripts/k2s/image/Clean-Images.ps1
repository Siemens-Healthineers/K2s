# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Remove all container images in K2s

.DESCRIPTION
Remove all container images in K2s
#>

param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$clusterModule = "$PSScriptRoot/../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$infraModule = "$PSScriptRoot/../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
Import-Module $clusterModule, $infraModule

Initialize-Logging -ShowLogs:$ShowLogs

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

$allContainerImages = Get-ContainerImagesInk2s -IncludeK8sImages $false
$deletedImages = @()

if ($allContainerImages.Count -eq 0) {
    $errMsg = 'Nothing to delete. '
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code 'no-images' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

$deletionfailed = $false
foreach ($containerImage in $allContainerImages) {
    $alreadyDeleted = $deletedImages | Where-Object { $containerImage.ImageId -eq $_ }
    if ($alreadyDeleted.Count -eq 0) {
        $errorString = Remove-Image -ContainerImage $containerImage
        if ($null -eq $errorString) {
            $deletedImages += $containerImage.ImageId
        }
        $deletionExitCode = Show-ImageDeletionStatus -ContainerImage $containerImage -ErrorMessage $errorString
        if($deletionExitCode -eq 1) {
            $deletionfailed = $true
        }
    }
    else {
        $image = $containerImage.Repository + ':' + $containerImage.Tag
        $imageId = $containerImage.ImageId
        $message = "No Action required for $image as Image Id $imageId is already deleted."
        Write-Log $message -Console
    }
}

if ($deletionfailed) {
    if ($EncodeStructuredOutput -eq $true) {
        $errMsg = "Not all images could be deleted!"
        $err = New-Error -Severity Warning -Code 'image-clean-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}


if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}