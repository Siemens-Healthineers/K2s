# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Export image to filesystem

.DESCRIPTION
Export image to filesystem

.PARAMETER Id
The image id of the image to be exported

.PARAMETER Name
The image name of the image to be exported

.PARAMETER ExportPath
The path where the image should be exported

.PARAMETER DockerArchive
Export as docker archive (default OCI archive)

.PARAMETER ShowLogs
Show all logs in terminal

.EXAMPLE
# Export container image with name "image:v1" to C:\temp\tmp.tar
PS> .\Export-Image.ps1 -Name "image:v1" -ExportPath "C:\temp\tmp.tar"

.EXAMPLE
# Export container image with id f8c20f8bbcb6 as Docker archive to C:\temp\tmp.tar
PS> .\Export-Image.ps1 -Id "f8c20f8bbcb6" -DockerArchive -ExportPath "C:\temp\tmp.tar"
#>

Param (
    [parameter(Mandatory = $false)]
    [string] $Id,
    [parameter(Mandatory = $false)]
    [string] $Name,
    [parameter(Mandatory = $false)]
    [string] $ExportPath,
    [parameter(Mandatory = $false)]
    [switch] $DockerArchive = $false,
    [parameter(Mandatory = $false)]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$infraModule = "$PSScriptRoot/../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$nodeModule = "$PSScriptRoot/../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"

Import-Module $infraModule, $clusterModule, $nodeModule

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

Write-Log "[DEBUG] Export-Image.ps1: Looking for image with Id='$Id' Name='$Name'"
$linuxContainerImages = Get-ContainerImagesOnLinuxNode -IncludeK8sImages $true
Write-Log "[DEBUG] Export-Image.ps1: Found $($linuxContainerImages.Count) linux container images"
$foundLinuxImages = @()
if ($Id -ne '') {
    Write-Log "[DEBUG] Export-Image.ps1: Searching by ImageId='$Id'"
    $foundLinuxImages = @($linuxContainerImages | Where-Object { $_.ImageId -eq $Id })
    Write-Log "[DEBUG] Export-Image.ps1: Found $($foundLinuxImages.Count) matching images by Id"
    # If multiple images match the same ID (e.g., one with tag and one with <none>),
    # prefer the one with an actual tag
    if ($foundLinuxImages.Count -gt 1) {
        $taggedImages = @($foundLinuxImages | Where-Object { $_.Tag -ne '<none>' })
        if ($taggedImages.Count -ge 1) {
            Write-Log "[DEBUG] Export-Image.ps1: Filtering to $($taggedImages.Count) tagged image(s) (excluding <none>)"
            $foundLinuxImages = @($taggedImages[0])
        } else {
            # All have <none> tag, just take the first one
            Write-Log "[DEBUG] Export-Image.ps1: All images have <none> tag, using first one"
            $foundLinuxImages = @($foundLinuxImages[0])
        }
    }
}
else {
    if ($Name -eq '') {
        Write-Error 'Image Name or ImageId is not provided. Cannot export image.'
    }
    else {
        $foundLinuxImages = @($linuxContainerImages | Where-Object {
                $imageName = $_.Repository + ':' + $_.Tag
                return ($imageName -eq $Name)
            })
    }
}

$windowsContainerImages = Get-ContainerImagesOnWindowsNode -IncludeK8sImages $true
$foundWindowsImages = @()
if ($Id -ne '') {
    $foundWindowsImages = @($windowsContainerImages | Where-Object { $_.ImageId -eq $Id })
    # If multiple images match the same ID (e.g., one with tag and one with <none>),
    # prefer the one with an actual tag
    if ($foundWindowsImages.Count -gt 1) {
        $taggedImages = @($foundWindowsImages | Where-Object { $_.Tag -ne '<none>' })
        if ($taggedImages.Count -ge 1) {
            Write-Log "[DEBUG] Export-Image.ps1: Filtering Windows to $($taggedImages.Count) tagged image(s) (excluding <none>)"
            $foundWindowsImages = @($taggedImages[0])
        } else {
            Write-Log "[DEBUG] Export-Image.ps1: All Windows images have <none> tag, using first one"
            $foundWindowsImages = @($foundWindowsImages[0])
        }
    }
}
else {
    if ($Name -eq '') {
        Write-Error 'Image Name or ImageId is not provided. Cannot export image.'
    }
    else {
        $foundWindowsImages = @($windowsContainerImages | Where-Object {
                $imageName = $_.Repository + ':' + $_.Tag
                return ($imageName -eq $Name)
            })
    }
}

if ($foundLinuxImages.Count -eq 0 -and $foundWindowsImages.Count -eq 0) {
    if ($Id -ne '') {
        $errMsg = "Image with Id ${Id} not found!"
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code 'image-not-found' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }

    if ($Name -ne '') {
        $errMsg = "Image ${Name} not found!"
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code 'image-not-found' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }
}

$windowsAndLinux = $($foundLinuxImages.Count -eq 1 -and $foundWindowsImages.Count -eq 1)

if ($foundLinuxImages.Count -eq 1) {
    Write-Log 'Linux image found!'
    $image = $foundLinuxImages[0]
    $imageId = $image.ImageId
    $imageName = $image.Repository
    $imageTag = $image.Tag
    $imageFullName = ''
    if ($imageTag -eq '<none>') {
        $imageFullName = $imageName
    }
    else {
        $imageFullName = "${imageName}:${imageTag}"
    }

    Write-Log "Exporting image ${imageFullName}. This can take some time..."

    $finalExportPath = $ExportPath

    if ($windowsAndLinux) {
        $filename = Split-Path -Path $ExportPath -Leaf
        $newFileName = $($filename -split '\.')[0] + '_linux.tar'
        $path = Split-Path -Path $ExportPath
        $finalExportPath = $path + '\' + $newFileName
    }

    if (!$DockerArchive) {
        (Invoke-CmdOnControlPlaneViaSSHKey "sudo buildah push ${imageId} oci-archive:/tmp/${imageId}.tar:${imageFullName} 2>&1" -NoLog).Output | Write-Log
    }
    else {
        (Invoke-CmdOnControlPlaneViaSSHKey "sudo buildah push ${imageId} docker-archive:/tmp/${imageId}.tar:${imageFullName} 2>&1" -NoLog).Output | Write-Log
    }

    $exportSuccess = $?
    Copy-FromControlPlaneViaSSHKey "/tmp/${imageId}.tar" $finalExportPath

    if ($exportSuccess -and $?) {
        Write-Log "Image ${imageFullName} exported successfully to ${finalExportPath}."
    }

    (Invoke-CmdOnControlPlaneViaSSHKey "cd /tmp && sudo rm -rf ${imageId}.tar" -NoLog).Output | Write-Log
}

if ($foundWindowsImages.Count -gt 1) {
    $errMsg = "Please specify the name and tag instead of id since there are more than one image with id $Id"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code 'image-not-found' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

if ($foundWindowsImages.Count -eq 1) {
    Write-Log 'Windows image found!'
    $image = $foundWindowsImages[0]
    $imageId = $image.ImageId
    $imageName = $image.Repository
    $imageTag = $image.Tag
    $imageFullName = ''
    if ($imageTag -eq '<none>') {
        $imageFullName = $imageName
    }
    else {
        $imageFullName = "${imageName}:${imageTag}"
    }
    Write-Log "Exporting image ${imageFullName}. This can take some time..."

    $finalExportPath = $ExportPath

    if ($windowsAndLinux) {
        $filename = Split-Path -Path $ExportPath -Leaf
        $newFileName = $($filename -split '\.')[0] + '_windows.tar'
        $path = Split-Path -Path $ExportPath
        $finalExportPath = $path + '\' + $newFileName
    }

    $binPath = Get-KubeBinPath
    $nerdctlExe = "$binPath\nerdctl.exe"

    Write-Log "Trying to pull all platform layers for image '$imageFullName'" -Console
    $pullOutput = &$nerdctlExe -n 'k8s.io' pull $imageFullName --all-platforms 2>&1 | Out-String
    if ($pullOutput.Contains('failed to do request')) {
        Write-Log "Not able to pull all platform layers for image '$imageFullName'" -Console
        Write-Log "Exporting image '$imageFullName' only for current platform" -Console
        &$nerdctlExe -n 'k8s.io' save -o "$finalExportPath" $imageFullName
    }
    else {
        Write-Log "Exporting image '$imageFullName' for all platforms" -Console
        &$nerdctlExe -n 'k8s.io' save -o "$finalExportPath" $imageFullName --all-platforms
    }

    if ($?) {
        Write-Log "Image ${imageFullName} exported successfully to ${finalExportPath}."
    }
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
