# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Tag container images in K2s

.DESCRIPTION
Tag container images in K2s

.PARAMETER Id
The image id of the image to be exported

.PARAMETER ImageName
The image name of the image to be tagged

.PARAMETER TargetImageName
The new image name 

.EXAMPLE
# Tag container image "image:v1" with new name "image:v2" in K2s
PS> .\Tag-Image.ps1 -ImageName "image:v1" -TargetImageName "image:v2"
#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Id of the image to be tagged with a new name')]
    [string] $Id,
    [parameter(Mandatory = $false, HelpMessage = 'Name of the image to be tagged with a new name.')]
    [string] $ImageName,
    [parameter(Mandatory = $true, HelpMessage = 'New image name')]
    [string] $TargetImageName,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$nodeModule = "$PSScriptRoot/../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"
$infraModule = "$PSScriptRoot/../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
Import-Module $nodeModule, $infraModule, $clusterModule

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

$linuxContainerImages = Get-ContainerImagesOnLinuxNode -IncludeK8sImages $true
$windowsContainerImages = Get-ContainerImagesOnWindowsNode -IncludeK8sImages $true

$foundLinuxImages = @()
if ($Id -ne '') {
    $foundLinuxImages = @($linuxContainerImages | Where-Object { $_.ImageId -eq $Id })
}
else {
    if ($ImageName -eq '') {
        Write-Error 'Image Name or ImageId is not provided. Cannot tag image.'
    }
    else {
        $foundLinuxImages = @($linuxContainerImages | Where-Object {
                $retrievedName = $_.Repository + ':' + $_.Tag
                return ($retrievedName -eq $ImageName)
            })
    }
}

$foundWindowsImages = @()
if ($Id -ne '') {
    $foundWindowsImages = @($windowsContainerImages | Where-Object { $_.ImageId -eq $Id })
}
else {
    if ($ImageName -eq '') {
        Write-Error 'Image Name or ImageId is not provided. Cannot tag image.'
    }
    else {
        $foundWindowsImages = @($windowsContainerImages | Where-Object {
                $retrievedName = $_.Repository + ':' + $_.Tag
                return ($retrievedName -eq $ImageName)
            })

    }
}


if ($foundLinuxImages.Count -eq 0 -and $foundWindowsImages.Count -eq 0) {
    If ($Id -ne '') {
        $errMsg = "Image with Id ${Id} not found!"
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code 'image-not-found' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }

    If ($ImageName -ne '') {
        $errMsg = "Image '$ImageName' not found"
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'image-tag-failed' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }
}

if ($foundLinuxImages.Count -gt 1 -or $foundWindowsImages.Count -gt 1) {
    $errMsg = "More than one image has the id: $Id. Please use --name to identify the image instead or delete the other image/s"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code 'two-images-found' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
}

$tagLinuxImage = $false
$tagWindowsImage = $false
$linuxAndWindowsImageFound = $false

if ($foundLinuxImages.Count -eq 1 -and $foundWindowsImages.Count -eq 1) {
    Write-Log 'Linux and Windows image found'
    $linuxAndWindowsImageFound = $true
    $answer = Read-Host 'WARNING: Linux and Windows image found. Which image should be tagged? (l/w) [Linux or Windows]'
    if ($answer -ne 'l' -and $answer -ne 'w') {
        $errMsg = 'Tag image cancelled.'
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code (Get-ErrCodeUserCancellation) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }

    if ($answer -eq 'l') {
        $tagLinuxImage = $true
    }

    if ($answer -eq 'w') {
        $tagWindowsImage = $true
    }
}

if ((($foundLinuxImages.Count -eq 1) -and !$linuxAndWindowsImageFound) -or $tagLinuxImage) {
    $image = $foundLinuxImages[0]
    $imageTag = $image.Tag
    $imageName = $image.Repository
    $ImageName = "${imageName}:${imageTag}"
    Write-Log "Tagging Linux image '$ImageName' as '$TargetImageName'" -Console
    $success = (Invoke-CmdOnControlPlaneViaSSHKey "sudo buildah tag $ImageName $TargetImageName 2>&1" -Retries 5).Success
    if (!$success) {
        $errMsg = "Error tagging image '$ImageName' as '$TargetImageName'"
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'image-tag-failed' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
    
        Write-Log $errMsg -Error
        exit 1
    }

    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null }
    }

    exit 0
}

if ((($foundWindowsImages.Count -eq 1) -and !$linuxAndWindowsImageFound) -or $tagWindowsImage) {
    $image = $foundWindowsImages[0]
    $imageTag = $image.Tag
    $imageName = $image.Repository
    $ImageName = "${imageName}:${imageTag}"
    Write-Log "Tagging Windows image '$ImageName' as '$TargetImageName'" -Console
    $kubeBinPath = Get-KubeBinPath
    $nerdctlExe = "$kubeBinPath\nerdctl.exe"
    $retries = 5
    $success = $false
    while ($retries -gt 0) {
        $retries--
        &$nerdctlExe -n="k8s.io" tag $ImageName $TargetImageName

        if ($?) {
            $success = $true
            break
        }
        Start-Sleep 1
    }

    if (!$success) {
        $errMsg = "Error tagging image '$ImageName' as '$TargetImageName'"
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'image-tag-failed' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
    
        Write-Log $errMsg -Error
        exit 1
    }

    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null }
    }

    exit 0
}