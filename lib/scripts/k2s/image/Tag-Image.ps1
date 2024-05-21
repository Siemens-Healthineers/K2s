# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
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

.EXAMPLE
# Tag container image "image:v1" with new name "image:v2" in K2s
PS> .\Tag-Image.ps1 -SourceImageName "image:v1" -TargetImageName "image:v2"
#>

Param (
    [parameter(Mandatory = $true, HelpMessage = 'Name of the image to be tagged with a new name.')]
    [string] $SourceImageName,
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

$images = @(Get-ContainerImagesInk2s -IncludeK8sImages $true)



if (!$Windows) {
    Write-Log "Pulling Linux image $ImageName"
    $success = (Invoke-CmdOnControlPlaneViaSSHKey "sudo buildah pull $ImageName 2>&1" -Retries 5).Success
    if (!$success) {
        $errMsg = "Error pulling image '$ImageName'"
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'image-pull-failed' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
    
        Write-Log $errMsg -Error
        exit 1
    }

    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null }
    }
    return
}
else {
    Write-Log "Pulling Windows image $ImageName"
    $kubeBinPath = Get-KubeBinPath
    $retries = 5
    $success = $false
    while ($retries -gt 0) {
        $retries--
        &$kubeBinPath\crictl pull $ImageName

        if ($?) {
            $success = $true
            break
        }
        Start-Sleep 1
    }

    if (!$success) {
        $errMsg = "Error pulling image '$ImageName'"
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'image-pull-failed' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
    
        Write-Log $errMsg -Error
        exit 1
    }
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}