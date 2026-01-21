# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
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
    $binPath = Get-KubeBinPath
    $nerdctlExe = "$binPath\nerdctl.exe"

    foreach ($image in $images) {
        &$nerdctlExe -n k8s.io load -i $image
        if ($?) {
            Write-Log "$image imported successfully"
        }
    }
}
else {
    foreach ($image in $images) {
        Write-Log "Importing image: $image"
        Copy-ToControlPlaneViaSSHKey $image '/tmp/import.tar'

        if (!$?) {
            Write-Log "Image $image could not be copied to KubeMaster" -Error
            continue
        }

        $buildahResult = $null
        if (!$DockerArchive) {
            $buildahResult = Invoke-CmdOnControlPlaneViaSSHKey 'sudo buildah pull oci-archive:/tmp/import.tar 2>&1' -NoLog
        }
        else {
            $buildahResult = Invoke-CmdOnControlPlaneViaSSHKey 'sudo buildah pull docker-archive:/tmp/import.tar 2>&1' -NoLog
        }

        $buildahResult.Output | Write-Log
        
        if ($buildahResult.Success) {
            Write-Log "Image archive $image imported successfully."
        } else {
            Write-Log "Failed to import image $image. Buildah output: $($buildahResult.Output)" -Error
        }

        (Invoke-CmdOnControlPlaneViaSSHKey 'cd /tmp && sudo rm -rf import.tar' -NoLog).Output | Write-Log
    }
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}