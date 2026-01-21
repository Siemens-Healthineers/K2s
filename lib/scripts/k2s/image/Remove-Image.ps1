# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Remove container image in K2s

.DESCRIPTION
Remove container image in K2s

.PARAMETER ImageId
The image id of the image to be removed

.PARAMETER ImageName
The image name of the image to be removed

.PARAMETER FromRegistry
Remove image from local storage as well as from local container registry

.EXAMPLE
# Remove image with image name 
PS> .\Remove-Image.ps1 -ImageName "image:v1"

.EXAMPLE
# Remove image with image id and from registry as well
PS> .\Remove-Image.ps1 -ImageId "f8c20f8bbcb6" -FromRegistry
#>

Param (
    [parameter(Mandatory = $false)]
    [string] $ImageId = '',
    [parameter(Mandatory = $false)]
    [string] $ImageName = '',
    [parameter(Mandatory = $false)]
    [switch] $FromRegistry,
    [parameter(Mandatory = $false, HelpMessage = 'Force removal by first removing any containers using the image')]
    [switch] $Force,
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

if ($FromRegistry) {
    $kubeToolsPath = Get-KubeToolsPath
    &"$kubeToolsPath\kubectl.exe" get namespace registry 2> $null | Out-Null
    if (!$?) {
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code 'registry-not-running' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }

    $pushedimages = Get-PushedContainerImages
    if ($ImageName -eq '') {
        $errMsg = 'ImageName incl. Tag is needed to remove image from registry. Cannot remove image.'
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code 'image-remove-failed' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
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

    $errMsg = "$ImageName could not be found."
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code 'image-not-found' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

$allContainerImages = Get-ContainerImagesInk2s -IncludeK8sImages $false
$foundImages = @()
if ($ImageId -ne '') {
    $foundImages = @($allContainerImages | Where-Object { $_.ImageId -eq $ImageId })
}
else {
    if ($ImageName -eq '') {
        $errMsg = 'Image Name or ImageId is not provided. Cannot remove image.'
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code 'image-remove-failed' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }
    else {
        $foundImages = @($allContainerImages | Where-Object {
                $calculatedName = $_.Repository + ':' + $_.Tag
                return ($calculatedName -eq $ImageName)
            })

    }
}

$deletionfailed = $false
if ($foundImages.Count -eq 0) {
    $errMsg = 'Image was not found. Please ensure that you have specified the right image details to be deleted'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code 'image-not-found' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}
else {
    $deletedImages = @()
    foreach ($imageToBeDeleted in $foundImages) {
        $alreadyDeleted = $deletedImages | Where-Object { $imageToBeDeleted.ImageId -eq $_ }
        if ($alreadyDeleted.Count -eq 0) {
            $errorString = Remove-Image -ContainerImage $imageToBeDeleted -Force:$Force
            if ($null -eq $errorString) {
                $deletedImages += $imageToBeDeleted.ImageId
            }
            $deletionExitCode = Show-ImageDeletionStatus -ContainerImage $imageToBeDeleted -ErrorMessage $errorString
            if($deletionExitCode -eq 1) {
                $deletionfailed = $true
            }
        }
        else {
            $image = $imageToBeDeleted.Repository + ':' + $imageToBeDeleted.Tag
            $imageId = $imageToBeDeleted.ImageId
            $message = "No Action required for $image as Image Id $imageId is already deleted."
            Write-Log $message
        }
    }
}

if ($deletionfailed) {
    if ($EncodeStructuredOutput -eq $true) {
        $errMsg = "Image couldn't be deleted!"
        $err = New-Error -Severity Warning -Code 'image-rm-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
