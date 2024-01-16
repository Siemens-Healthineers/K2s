# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Creates a VHDX image from an Hyper-v VM Instance

.DESCRIPTION
...

.EXAMPLE
PS> .\CreateVHDXImage.ps1 -VMName Windows10CTColon -OutputPath d:\out


#>
Param(
    [parameter(Mandatory = $true, HelpMessage = 'Hyper-v VM Name')]
    [string] $Name,
    [parameter(Mandatory = $true, HelpMessage = 'VHDX VM Image output path')]
    [string] $OutputPath
)

$mainStopwatch = [system.diagnostics.stopwatch]::StartNew()

# load global settings
&$PSScriptRoot\..\GlobalVariables.ps1

Write-Output "Creating VHDX image file"
$imageName = '\' + $Name + '.vhdx'
$vhdxImagePath = Join-Path -Path $OutputPath -ChildPath $imageName
Write-Output 'VHDX image path: ' $vhdxImagePath

try {
    [Environment]::CurrentDirectory = (Get-Location -PSProvider FileSystem).ProviderPath
    Write-Output 'VM name is: ' $Name
    $vm = Get-VM -VMName $Name -ErrorAction SilentlyContinue
    if ($Null -eq $vm) {
        throw ('VM {0} does not exist.' -f @($Name))
    }

    $disk = Get-VMHardDiskDrive -VMName $Name -ErrorAction SilentlyContinue
    if ($Null -eq $disk) {
        throw ('Failed to get VM disk path.' )
    }
    else {
        Write-Output 'VM Disk path: ' $disk.Path
    }

    $vmDiskPath = $disk.Path
    $vmFile = Get-Item $vmDiskPath
    $fileExtension = $vmFile.Extension

    if ($fileExtension -ne '.vhdx') {
        throw ('VM disk is not of vhdx type.' )
    }

    #Copy VHDX to Output path
    Copy-Item $vmDiskPath -Destination $vhdxImagePath -Force | Out-Null
    Write-Output "Creation of VHDX image generation is finished. Image path: $vhdxImagePath"
}
catch { 
    Write-Output $_
    if (Test-Path $vhdxImagePath) {
        Remove-Item -Force $vhdxImagePath
    }
}

Write-Output "Total duration: $('{0:hh\:mm\:ss}' -f $mainStopwatch.Elapsed )"