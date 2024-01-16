# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Pull container images in k2s

.DESCRIPTION
Pull container images in k2s

.PARAMETER ImageName
The image name of the image to be pulled

.PARAMETER Windows
Indicates that it is a windows image

.EXAMPLE
# Pull linux container image with name "image:v1" in k2s
PS> .\Pull-Image.ps1 -ImageName "image:v1"

.EXAMPLE
# Pull windows container image with name "image:v1" in k2s
PS> .\Pull-Image.ps1 -ImageName "image:v1" -Windows
#>

Param (
    [parameter(Mandatory = $true, HelpMessage = 'Name of the image to be pulled.')]
    [string] $ImageName,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, the image will be pulled for windows 10 node.')]
    [switch] $Windows,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)

$nodeModule = "$PSScriptRoot/../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"
$infraModule = "$PSScriptRoot/../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
Import-Module $nodeModule, $infraModule

Initialize-Logging -ShowLogs:$ShowLogs

if (!$Windows) {
    Invoke-CmdOnControlPlaneViaSSHKey "sudo buildah pull $ImageName 2>&1" -Retries 5 -NoLog
}
else {
    $retries = 5
    $success = $false
    while ($retries -gt 0) {
        $retries--
        crictl pull $ImageName

        if ($?) {
            $success = $true
            break
        }
        Start-Sleep 1
    }

    if (!$success) {
        throw "Error pulling image '$ImageName'"
    }
}