# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Push container images in K2s

.DESCRIPTION
Push container images in K2s

.PARAMETER ImageName
The image name of the image to be pushed

.EXAMPLE
# Push container image with name "image:v1" in K2s
PS> .\Push-Image.ps1 -ImageName "image:v1"
#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Id of the image to be pushed.')]
    [string] $Id,
    [parameter(Mandatory = $false, HelpMessage = 'Name of the image to be pushed.')]
    [string] $ImageName,
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

$foundLinuxImages = @()
if ($Id -ne '') {
    $foundLinuxImages = @($linuxContainerImages | Where-Object { $_.ImageId -eq $Id })
}
else {
    if ($ImageName -eq '') {
        Write-Error 'Image Name or ImageId is not provided. Cannot push the image.'
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
        Write-Error 'Image Name or ImageId is not provided. Cannot push the image.'
    }
    else {
        $foundWindowsImages = @($windowsContainerImages | Where-Object {
                $retrievedName = $_.Repository + ':' + $_.Tag
                return ($retrievedName -eq $ImageName)
            })
    }
}

if ($foundLinuxImages.Count -eq 0 -and $foundWindowsImages.Count -eq 0) {
    If ($Id -ne ''){
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

$pushLinuxImage = $false
$pushWindowsImage = $false
$linuxAndWindowsImageFound = $false

if ($foundLinuxImages.Count -eq 1 -and $foundWindowsImages.Count -eq 1) {
    Write-Log "Linux and Windows image found"
    $linuxAndWindowsImageFound = $true
    $answer = Read-Host 'WARNING: Linux and Windows image found. Which image should be pushed? (l/w) [Linux or Windows]'
    if ($answer -ne 'l' -and $answer -ne 'w') {
        $errMsg = 'Push image cancelled.'
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code (Get-ErrCodeUserCancellation) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }

    if ($answer -eq 'l') {
        $pushLinuxImage = $true
    }

    if ($answer -eq 'w') {
        $pushWindowsImage = $true
    }
}

if ((($foundLinuxImages.Count -eq 1) -and !$linuxAndWindowsImageFound) -or $pushLinuxImage) {
    $image = $foundLinuxImages[0]
    $imageTag = $image.Tag
    $imageName = $image.Repository
    $ImageName = "${imageName}:${imageTag}"
    Write-Log "Pushing Linux image $ImageName" -Console
    $success = (Invoke-CmdOnControlPlaneViaSSHKey "sudo buildah push $ImageName 2>&1" -Retries 5).Success
    if (!$success) {
        $errMsg = "Error pushing image '$ImageName'"
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'image-push-failed' -Message $errMsg
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

if ((($foundWindowsImages.Count -eq 1) -and !$linuxAndWindowsImageFound) -or $pushWindowsImage) {
    $image = $foundWindowsImages[0]
    $imageTag = $image.Tag
    $imageName = $image.Repository
    $ImageName = "${imageName}:${imageTag}"
    Write-Log "Pushing Windows image $ImageName" -Console
    $kubeBinPath = Get-KubeBinPath
    $nerdctlExe = "$kubeBinPath\nerdctl.exe"
    $retries = 5
    $success = $false
    while ($retries -gt 0) {
        $retries--
        $(&$nerdctlExe -n="k8s.io" --insecure-registry image push $ImageName --allow-nondistributable-artifacts --quiet 2>&1) | Out-String

        if ($?) {
            $success = $true
            break
        }
        Start-Sleep 1
    }

    if (!$success) {
        $errMsg = "Error pushing image '$ImageName'"
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'image-push-failed' -Message $errMsg
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