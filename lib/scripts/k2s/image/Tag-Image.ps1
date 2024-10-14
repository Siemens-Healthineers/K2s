# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Tag container images in K2s

.DESCRIPTION
Tag container images in K2s

.PARAMETER ImageName
The image name of the image to be tagged

.PARAMETER TargetImageName
The new image name 

.EXAMPLE
# Tag container image "image:v1" with new name "image:v2" in K2s
PS> .\Tag-Image.ps1 -ImageName "image:v1" -TargetImageName "image:v2"
#>

Param (
    [parameter(Mandatory = $true, HelpMessage = 'Name of the image to be tagged with a new name.')]
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

$WorkerVM = Get-IsWorkerVM
$linuxContainerImages = Get-ContainerImagesOnLinuxNode -IncludeK8sImages $true
$windowsContainerImages = Get-ContainerImagesOnWindowsNode -IncludeK8sImages $true -WorkerVM $WorkerVM

$foundLinuxImages = @($linuxContainerImages | Where-Object {
    $calculatedName = $_.Repository + ':' + $_.Tag
    return ($calculatedName -eq $ImageName)
})

$foundWindowsImages = @($windowsContainerImages | Where-Object {
    $calculatedName = $_.Repository + ':' + $_.Tag
    return ($calculatedName -eq $ImageName)
})

if ($foundLinuxImages.Count -eq 0 -and $foundWindowsImages.Count -eq 0) {
    $errMsg = "Image '$ImageName' not found"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'image-tag-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$tagLinuxImage = $false
$tagWindowsImage = $false
$linuxAndWindowsImageFound = $false

if ($foundLinuxImages.Count -eq 1 -and $foundWindowsImages.Count -eq 1) {
    Write-Log "Linux and Windows image found"
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