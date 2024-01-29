# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
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
The path where the image sould be exported

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
    [switch] $ShowLogs = $false
)

$nodeModule = "$PSScriptRoot/../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"
$infraModule = "$PSScriptRoot/../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
Import-Module $nodeModule, $infraModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

$systemError = Test-SystemAvailability
if ($systemError) {
    throw $systemError
}

$linuxContainerImages = Get-ContainerImagesOnLinuxNode -IncludeK8sImages $true
$foundLinuxImages = @()
if ($Id -ne '') {
    $foundLinuxImages = @($linuxContainerImages | Where-Object { $_.ImageId -eq $Id })
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
        Write-Log "Image with Id ${Id} not found!"
        exit
    }

    if ($Name -ne '') {
        Write-Log "Image ${Name} not found!"
        exit
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
        Invoke-CmdOnControlPlaneViaSSHKey "sudo buildah push ${imageId} oci-archive:/tmp/${imageId}.tar:${imageFullName} 2>&1" -NoLog
    }
    else {
        Invoke-CmdOnControlPlaneViaSSHKey "sudo buildah push ${imageId} docker-archive:/tmp/${imageId}.tar:${imageFullName} 2>&1" -NoLog
    }
    
    $exportSuccess = $?
    Copy-FromControlPlaneViaSSHKey "/tmp/${imageId}.tar" $finalExportPath

    if ($exportSuccess -and $?) {
        Write-Log "Image ${imageFullName} exported successfully to ${finalExportPath}."
    }

    Invoke-CmdOnControlPlaneViaSSHKey "cd /tmp && sudo rm -rf ${imageId}.tar" -NoLog
}

if ($foundWindowsImages.Count -gt 1) {
    Write-Log "Please specify the name and tag instead of id since there are more than one image with id $Id"
    return
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

    nerdctl -n k8s.io save -o "$finalExportPath" $imageFullName
    
    if ($?) {
        Write-Log "Image ${imageFullName} exported successfully to ${finalExportPath}."
    }
}
