# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

# RemoveImage.ps1

<#
.Description
remove container images present in K2s
#>

Param (
    [parameter(Mandatory = $false)]
    [string] $ImageId = '',
    [parameter(Mandatory = $false)]
    [string] $ImageName = '',
    [parameter(Mandatory = $false)]
    [switch] $FromRegistry,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)

Import-Module $PSScriptRoot\ImageFunctions.module.psm1 -DisableNameChecking

Test-ClusterAvailabilityForImageFunctions

if ($FromRegistry) {
    kubectl get namespace registry 2> $null | Out-Null
    if (!$?) {
        Write-Error 'k2s-registry.local is not running.'
        return
    }

    $pushedimages = Get-PushedContainerImages
    if ($ImageName -eq '') {
        Write-Error 'ImageName incl. Tag is needed to remove image from registry. Cannot remove image.'
    }
    else {
        foreach ($image in $pushedimages ) {
            if ($($image.Name + ':' + $image.Tag) -eq $ImageName) {
                Remove-PushedImage $image.Name $image.Tag
                return
            }
        }

        Write-Host "$ImageName could not be found."
    }

    return
}

$allContainerImages = Get-ContainerImagesInk2s -IncludeK8sImages $false
$foundImages = @()
if ($ImageId -ne '') {
    $foundImages = @($allContainerImages | Where-Object { $_.ImageId -eq $ImageId })
}
else {
    if ($ImageName -eq '') {
        Write-Error 'Image Name or ImageId is not provided. Cannot remove image.'
    }
    else {
        $foundImages = @($allContainerImages | Where-Object {
                $calculatedName = $_.Repository + ':' + $_.Tag
                return ($calculatedName -eq $ImageName)
            })

    }
}

if ($foundImages.Count -eq 0) {
    Write-Error 'Image was not found. Please ensure that you have specified the right image details to be deleted'
}
else {
    $deletedImages = @()
    foreach ($imageToBeDeleted in $foundImages) {
        $alreadyDeleted = $deletedImages | Where-Object { $imageToBeDeleted.ImageId -eq $_ }
        if ($alreadyDeleted.Count -eq 0) {
            $errorString = Remove-Image -ContainerImage $imageToBeDeleted
            if ($null -eq $errorString) {
                $deletedImages += $imageToBeDeleted.ImageId
            }
            Show-ImageDeletionStatus -ContainerImage $imageToBeDeleted -ErrorMessage $errorString
        }
        else {
            $image = $imageToBeDeleted.Repository + ':' + $imageToBeDeleted.Tag
            $imageId = $imageToBeDeleted.ImageId
            $message = "No Action required for $image as Image Id $imageId is already deleted."
            Write-Host $message
        }
    }
}
