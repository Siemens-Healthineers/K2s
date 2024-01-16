# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

# CleanImages.ps1

<#
.Description
Removes all container images present in k2s
#>

param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)

Import-Module $PSScriptRoot\ImageFunctions.module.psm1 -DisableNameChecking

Test-ClusterAvailabilityForImageFunctions

$allContainerImages = Get-ContainerImagesInk2s -IncludeK8sImages $false
$deletedImages = @()

if ($allContainerImages.Count -eq 0) {
    Write-Host "Nothing to delete. "
}

foreach ($containerImage in $allContainerImages) {
    $alreadyDeleted = $deletedImages | Where-Object { $containerImage.ImageId -eq $_ }
    if ($alreadyDeleted.Count -eq 0) {
        $errorString = Remove-Image -ContainerImage $containerImage
        if ($null -eq $errorString) {
            $deletedImages += $imageToBeDeleted.ImageId
        }
        Show-ImageDeletionStatus -ContainerImage $containerImage -ErrorMessage $errorString
    } else {
        $image = $containerImage.Repository + ":" + $containerImage.Tag
        $imageId = $containerImage.ImageId
        $message = "No Action required for $image as Image Id $imageId is already deleted."
        Write-Host $message
    }
}