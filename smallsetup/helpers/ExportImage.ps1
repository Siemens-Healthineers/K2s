# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
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
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
&$PSScriptRoot\..\common\GlobalVariables.ps1
. $PSScriptRoot\..\common\GlobalFunctions.ps1

$clusterModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
$imageFunctionsModule = "$PSScriptRoot\ImageFunctions.module.psm1"
$loggingModule = "$PSScriptRoot\..\ps-modules\log\log.module.psm1"
$infraModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"

Import-Module $clusterModule, $imageFunctionsModule, $loggingModule, $infraModule -DisableNameChecking

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
    Write-Log 'Linux image found'
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

    Write-Log "Exporting image ${imageFullName}. This can take some time..." -Console

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
        Write-Log "Image ${imageFullName} exported successfully to ${finalExportPath}." -Console
    }

    ExecCmdMaster "cd /tmp && sudo rm -rf ${imageId}.tar" -NoLog
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
    Write-Log "Exporting image ${imageFullName}. This can take some time..." -Console

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
        $tmpPath = 'C:\temp\tmp.tar'
        Invoke-Command -Session $session {
            Set-Location "$env:SystemDrive\k"
            Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

            # load global settings
            &$env:SystemDrive\k\smallsetup\common\GlobalVariables.ps1

            Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1
            Initialize-Logging -Nested:$true

            New-Item -Path $(Split-path $using:tmpPath) -ItemType Directory -ErrorAction SilentlyContinue
            Write-Log "Trying to pull all platform layers for image '$imageFullName'" -Console
            $pullOutput = &$global:NerdctlExe -n="k8s.io" pull $using:imageFullName --all-platforms 2>&1 | Out-String
            if ($pullOutput.Contains("failed to do request")) {
                Write-Log "Not able to pull all platform layers for image '$imageFullName'" -Console
                Write-Log "Exporting image '$imageFullName' only for current platform" -Console
                &$global:NerdctlExe -n k8s.io save -o $using:tmpPath $using:imageFullName
            } else {
                Write-Log "Exporting image '$imageFullName' for all platforms" -Console
                &$global:NerdctlExe -n k8s.io save -o $using:tmpPath $using:imageFullName --all-platforms
            }
        }

        Copy-Item "$tmpPath" -Destination "$finalExportPath" -Recurse -FromSession $session -Force
    }
    else {
        Write-Log "Trying to pull all platform layers for image '$imageFullName'" -Console
        $pullOutput = &$global:NerdctlExe -n "k8s.io" pull $imageFullName --all-platforms 2>&1 | Out-String
        if ($pullOutput.Contains("failed to do request")) {
            Write-Log "Not able to pull all platform layers for image '$imageFullName'" -Console
            Write-Log "Exporting image '$imageFullName' only for current platform" -Console
            &$global:NerdctlExe -n "k8s.io" save -o "$finalExportPath" $imageFullName
        } else {
            Write-Log "Exporting image '$imageFullName' for all platforms" -Console
            &$global:NerdctlExe -n "k8s.io" save -o "$finalExportPath" $imageFullName --all-platforms
        }
    }

    if ($?) {
        Write-Log "Image ${imageFullName} exported successfully to ${finalExportPath}." -Console
    }
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}