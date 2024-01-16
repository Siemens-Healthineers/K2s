# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Upload image linux node in Small K8s Setup

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

$mainStopwatch = [system.diagnostics.stopwatch]::StartNew()



# load global settings
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1

Write-Host "[$(Get-Date -Format HH:mm:ss)] uploading $Image to master VM"

$source = $Image
$target = "$global:Remote_Master" + ':/mnt/win10img/disk.img'
Copy-FromToMaster $source $target

Write-Host "Total duration: $('{0:hh\:mm\:ss}' -f $mainStopwatch.Elapsed )"