# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
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
    [switch] $ShowLogs = $false
)

$clusterModule = "$PSScriptRoot/../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$infraModule = "$PSScriptRoot/../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
Import-Module $clusterModule, $infraModule

Initialize-Logging -ShowLogs:$ShowLogs

$systemError = Test-SystemAvailability
if ($systemError) {
    throw $systemError
}

$allContainerImages = Get-ContainerImagesInk2s -IncludeK8sImages $false
$deletedImages = @()

if ($allContainerImages.Count -eq 0) {
    Write-Log 'Nothing to delete. '
}

foreach ($containerImage in $allContainerImages) {
    $alreadyDeleted = $deletedImages | Where-Object { $containerImage.ImageId -eq $_ }
    if ($alreadyDeleted.Count -eq 0) {
        $errorString = Remove-Image -ContainerImage $containerImage
        if ($null -eq $errorString) {
            $deletedImages += $imageToBeDeleted.ImageId
        }
        Show-ImageDeletionStatus -ContainerImage $containerImage -ErrorMessage $errorString
    }
    else {
        $image = $containerImage.Repository + ':' + $containerImage.Tag
        $imageId = $containerImage.ImageId
        $message = "No Action required for $image as Image Id $imageId is already deleted."
        Write-Log $message
    }
}