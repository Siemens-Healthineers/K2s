# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Import image from filesystem

.DESCRIPTION
Import image from filesystem

.PARAMETER ImagePath
The image path of the image to be imported

.PARAMETER ImageDir
The directory of the images to be imported

.PARAMETER Windows
Image to import is a Windows image

.PARAMETER DockerArchive
Import a docker archive (default OCI archive)

.PARAMETER ShowLogs
Show all logs in terminal

.EXAMPLE
# Import windows container image from C:\temp\tmp.tar
PS> .\Import-Image.ps1 -ImagePath "C:\temp\tmp.tar" -Windows

.EXAMPLE
# Import all container image from directory C:\temp
PS> .\Import-Image.ps1 -ImageDir "C:\temp"
#>

Param (
    [parameter(Mandatory = $false)]
    [string] $ImagePath,
    [parameter(Mandatory = $false)]
    [string] $ImageDir,
    [parameter(Mandatory = $false)]
    [switch] $Windows = $false,
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

$images = @()
if ($ImagePath -ne '') {
    $images += $ImagePath
    Write-Log "Importing image $ImagePath. This can take some time..."
}
elseif ($ImageDir -ne '') {
    $files = Get-Childitem -recurse $ImageDir | Where-Object { $_.Name -match '.*.tar' } | ForEach-Object { $_.Fullname }
    $images += $files
    Write-Log "Importing images from $ImageDir. This can take some time..."
}

if ($Windows) {
    foreach ($image in $images) {
        nerdctl -n k8s.io load -i $image
        if ($?) {
            Write-Log "$image imported successfully"
        }
    }
}
else {
    foreach ($image in $images) {
        Copy-ToControlPlaneViaSSHKey $image '/tmp/import.tar'

        if (!$?) {
            Write-Error "Image $image could not be copied to KubeMaster"
        }

        if (!$DockerArchive) {
            Invoke-CmdOnControlPlaneViaSSHKey 'sudo buildah pull oci-archive:/tmp/import.tar 2>&1' -NoLog
        }
        else {
            Invoke-CmdOnControlPlaneViaSSHKey 'sudo buildah pull docker-archive:/tmp/import.tar 2>&1' -NoLog
        }

        if ($?) {
            Write-Log "Image archive $image imported successfully."
        }

        Invoke-CmdOnControlPlaneViaSSHKey 'cd /tmp && sudo rm -rf import.tar' -NoLog
    }
}