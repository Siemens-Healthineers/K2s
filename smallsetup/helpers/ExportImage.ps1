# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

# ExportImage.ps1

<#
.Description
Export image to oci tar archive to a specific path
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

# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\..\common\GlobalFunctions.ps1

$setupInfoModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.cluster.module\setupinfo\setupinfo.module.psm1"
$imageFunctionsModule = "$PSScriptRoot\ImageFunctions.module.psm1"
$loggingModule = "$PSScriptRoot\..\ps-modules\log\log.module.psm1"
Import-Module $setupInfoModule, $imageFunctionsModule, $loggingModule -DisableNameChecking
Initialize-Logging -ShowLogs:$ShowLogs

Test-ClusterAvailabilityForImageFunctions

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
        ExecCmdMaster "sudo buildah push ${imageId} oci-archive:/tmp/${imageId}.tar:${imageFullName} 2>&1" -NoLog
    }
    else {
        ExecCmdMaster "sudo buildah push ${imageId} docker-archive:/tmp/${imageId}.tar:${imageFullName} 2>&1" -NoLog
    }
    
    $exportSuccess = $?
    Copy-FromToMaster $($global:Remote_Master + ':' + "/tmp/${imageId}.tar") $finalExportPath

    if ($exportSuccess -and $?) {
        Write-Log "Image ${imageFullName} exported successfully to ${finalExportPath}."
    }

    ExecCmdMaster "cd /tmp && sudo rm -rf ${imageId}.tar" -NoLog
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

    $setupInfo = Get-SetupInfo
    if ($setupInfo.Name -eq $global:SetupType_MultiVMK8s) {
        $session = Open-RemoteSessionViaSSHKey $global:Admin_WinNode $global:WindowsVMKey
        $tmpPath = 'C:\\temp\\tmp.tar'
        Invoke-Command -Session $session {
            Set-Location "$env:SystemDrive\k"
            Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

            # load global settings
            &$env:SystemDrive\k\smallsetup\common\GlobalVariables.ps1

            New-Item -Path $(Split-path $using:tmpPath) -ItemType Directory -ErrorAction SilentlyContinue
            &$global:NerdctlExe -n k8s.io save -o $using:tmpPath $using:imageFullName
        }

        scp.exe -r -q -o StrictHostKeyChecking=no -i $global:WindowsVMKey "${global:Admin_WinNode}:$tmpPath" "$finalExportPath" 2>&1 | % { "$_" }
    }
    else {
        &$global:NerdctlExe -n k8s.io save -o "$finalExportPath" $imageFullName
    }
    
    if ($?) {
        Write-Log "Image ${imageFullName} exported successfully to ${finalExportPath}."
    }
}

