# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Upload image linux node in K2s Setup

.DESCRIPTION
Kubevirt is needed for running VMs in Kubernetes for apps which cannot containerized
This script upload an image

.EXAMPLE
PS> .\UploadImage.ps1 -Image c:\out\en_windows_10_21h1_x64.iso
#>
Param(
    [parameter(Mandatory = $true, HelpMessage = 'Image file')]
    [string] $Image
)
Import-Module "$PSScriptRoot\..\..\lib\modules\k2s\k2s.node.module\linuxnode\vm\vm.module.psm1"

$mainStopwatch = [system.diagnostics.stopwatch]::StartNew()

Write-Host "[$(Get-Date -Format HH:mm:ss)] Uploading $Image to control plane"

Copy-ToControlPlaneViaSSHKey $Image '/mnt/win10img/disk.img'

Write-Host "Total duration: $('{0:hh\:mm\:ss}' -f $mainStopwatch.Elapsed )"