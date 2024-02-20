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
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$imageModule = "$PSScriptRoot\ImageFunctions.module.psm1"
$statusModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.cluster.module\status\status.module.psm1"
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"

Import-Module $imageModule, $statusModule, $infraModule

Initialize-Logging -ShowLogs:$ShowLogs

$systemError = Test-SystemAvailability
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError -Error
    exit 1
}

if ($FromRegistry) {
    &$global:KubectlExe get namespace registry 2> $null | Out-Null
    if (!$?) {
        Write-Error 'k2s-registry.local is not running.'
        if ($EncodeStructuredOutput -eq $true) {
            Send-ToCli -MessageType $MessageType -Message @{Error = $null }
        }
        return
    }

    $pushedimages = Get-PushedContainerImages
    if ($ImageName -eq '') {
        Write-Error 'ImageName incl. Tag is needed to remove image from registry. Cannot remove image.'
        if ($EncodeStructuredOutput -eq $true) {
            Send-ToCli -MessageType $MessageType -Message @{Error = $null }
        }
        return
    }

    foreach ($image in $pushedimages ) {
        if ($($image.Name + ':' + $image.Tag) -eq $ImageName) {
            Remove-PushedImage $image.Name $image.Tag

            if ($EncodeStructuredOutput -eq $true) {
                Send-ToCli -MessageType $MessageType -Message @{Error = $null }
            }
            return
        }
    }

    Write-Log "$ImageName could not be found." -Console

    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null }
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
        if ($EncodeStructuredOutput -eq $true) {
            Send-ToCli -MessageType $MessageType -Message @{Error = $null }
        }
        return
    }

    $foundImages = @($allContainerImages | Where-Object {
            $calculatedName = $_.Repository + ':' + $_.Tag
            return ($calculatedName -eq $ImageName)
        })
}

if ($foundImages.Count -eq 0) {
    Write-Error 'Image was not found. Please ensure that you have specified the right image details to be deleted'
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null }
    }
    return
}

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
        Write-Log $message -Console
    }
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}