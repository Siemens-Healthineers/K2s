# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Build a new Linux image based on a qcow2 image

.DESCRIPTION
Builds a Linux docker image using k2s on the Linux VM.
Optionally pushes the created image to the repository (only with -Push)

.EXAMPLE
PS> .\BuildKubevirtImage.ps1 -InputQCOW2Image E:\QCOW2\windows20h2.qcow2 -ImageName virt-win20h2
PS> .\BuildKubevirtImage.ps1 -ImageName testserver -ImageTag 76 -Push

#>

Param(
    [Alias('d')]
    [parameter(Mandatory = $true, HelpMessage = 'Directory with the Dockerfile')]
    [string] $InputQCOW2Image,

    [parameter(Mandatory = $true, HelpMessage = 'Name of the created image')]
    [string] $ImageName,

    [Alias('t', 'Tag')]
    [parameter(Mandatory = $false, HelpMessage = 'Tag in registry')]
    [string] $ImageTag = 'local',

    [Alias('p')]
    [parameter(Mandatory = $false, HelpMessage = 'Push image to repository')]
    [switch] $Push = $false
)

$mainStopwatch = [system.diagnostics.stopwatch]::StartNew()

# load global settings
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1

if (! (Test-Path "$InputQCOW2Image")) { Log-ErrorWithThrow "Missing QCOW2 image file: $InputQCOW2Image" }
if (($ImageTag -eq 'local') -and $Push) { Log-ErrorWithThrow 'Unable to push without valid tag, use -ImageTag' }
if ($ImageName -eq '') { Log-ErrorWithThrow 'Missing image name' }

Write-Output "[$(Get-Date -Format HH:mm:ss)] Creating linux container: $ImageName from QCOW2 image: $InputQCOW2Image"

$storageLocalDrive = Get-StorageLocalDrive
$storagePath = "$storageLocalDrive\kubevirt"
Write-Output "[$(Get-Date -Format HH:mm:ss)] Creating directory $storagePath"
mkdir -force $storagePath | Out-Null

# filter out drive and file name
$fileqcow2 = Split-Path -Path $InputQCOW2Image -leaf
$driveqcow2 = Split-Path -Path $InputQCOW2Image -Qualifier

# check file existence
if (! (Test-Path "$storagePath\$fileqcow2")) {
    if ( $driveqcow2 -eq $storageLocalDrive) {
        # make link if drive the same
        Write-Output "[$(Get-Date -Format HH:mm:ss)] Make link $storagePath\$fileqcow2 -> $InputQCOW2Image"
        New-Item -Path $storagePath\$fileqcow2 -ItemType SymbolicLink -Value $InputQCOW2Image
    }
    else {
        # else copy file
        Write-Output "[$(Get-Date -Format HH:mm:ss)] Copy file 2 $InputQCOW2Image -> $storagePath\$fileqcow"
        Copy-Item -Path $InputQCOW2Image -Destination $storagePath
    }
}
else {
    Write-Output "[$(Get-Date -Format HH:mm:ss)] File already available, reusing that: $storagePath\$fileqcow2"
}

# build container file
$containerfile = "$storagePath\Dockerfile";
Remove-Item -Path "$storagePath\Dockerfile" -Force -ErrorAction SilentlyContinue
Write-Output "[$(Get-Date -Format HH:mm:ss)] Build $containerfile"
Add-Content -Path $containerfile -Value 'FROM scratch' -Force
Add-Content -Path $containerfile -Value "ADD $fileqcow2 /disk/" -Force

# build container
if ( $Push ) {
    &"$global:KubernetesPath\smallsetup\common\BuildImage.ps1" -InputFolder $storagePath -ImageName $ImageName -ImageTag $ImageTag -Push -ShowLogs
}
else {
    &"$global:KubernetesPath\smallsetup\common\BuildImage.ps1" -InputFolder $storagePath -ImageName $ImageName -ImageTag $ImageTag -ShowLogs
}


Write-Host "Total duration: $('{0:hh\:mm\:ss}' -f $mainStopwatch.Elapsed )"