# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VirtioIsoPath,

    [Parameter(Mandatory = $true)]
    [string]$ImagePath,

    [int]$ImageIndex = 1
)

Import-Module "$PSScriptRoot\..\..\ps-modules\log\log.module.psm1"

$ErrorActionPreference = 'Stop'



#
# Source: https://pve.proxmox.com/wiki/Windows_10_guest_best_practices
#



#
# Functions
#

function With-IsoImage([string]$IsoFileName, [scriptblock]$ScriptBlock) {
    $IsoFileName = (Resolve-Path $IsoFileName).Path

    Write-Log "Mounting '$IsoFileName'..."
    $mountedImage = Mount-DiskImage -ImagePath $IsoFileName -StorageType ISO -PassThru
    try {
        $driveLetter = ($mountedImage | Get-Volume).DriveLetter
        Invoke-Command $ScriptBlock -ArgumentList $driveLetter
    }
    finally {
        Write-Log "Dismounting '$IsoFileName'..."
        Dismount-DiskImage -ImagePath $IsoFileName | Out-Null
    }
}

function With-WindowsImage([string]$ImagePath, [int]$ImageIndex, [string]$VirtioDriveLetter, [scriptblock]$ScriptBlock) {
    $mountPath = Join-Path ([System.IO.Path]::GetTempPath()) 'winmount\'

    Write-Log "Mounting '$ImagePath' ($ImageIndex)..."
    mkdir $mountPath -Force | Out-Null
    Mount-WindowsImage -Path $mountPath -ImagePath $ImagePath -Index $ImageIndex | Out-Null
    try {
        Invoke-Command $ScriptBlock -ArgumentList $mountPath
    }
    finally {
        Write-Log "Dismounting '$ImagePath' ($ImageIndex)..."
        Dismount-WindowsImage -Path $mountPath -Save | Out-Null
    }
}

function Add-DriversToWindowsImage($ImagePath, $ImageIndex, $VirtioDriveLetter) {
    With-WindowsImage -ImagePath $ImagePath -ImageIndex $ImageIndex -VirtioDriveLetter $VirtioDriveLetter {
        Param($mountPath)

        Write-Log "  Adding driver 'vioscsi'..."
        Add-WindowsDriver -Path $mountPath -Driver "$($VirtioDriveLetter):\vioscsi\w10\amd64" -Recurse -ForceUnsigned

        Write-Log "  Adding driver 'NetKVM'..."
        Add-WindowsDriver -Path $mountPath -Driver "$($VirtioDriveLetter):\NetKVM\w10\amd64" -Recurse -ForceUnsigned

        Write-Log "  Adding driver 'Balloon'..."
        Add-WindowsDriver -Path $mountPath -Driver "$($VirtioDriveLetter):\Balloon\w10\amd64" -Recurse -ForceUnsigned

        Write-Log "  Adding driver 'pvpanic'..."
        Add-WindowsDriver -Path $mountPath -Driver "$($VirtioDriveLetter):\pvpanic\w10\amd64" -Recurse -ForceUnsigned

        Write-Log "  Adding driver 'qemupciserial'..."
        Add-WindowsDriver -Path $mountPath -Driver "$($VirtioDriveLetter):\qemupciserial\w10\amd64" -Recurse -ForceUnsigned

        Write-Log "  Adding driver 'qxldod'..."
        Add-WindowsDriver -Path $mountPath -Driver "$($VirtioDriveLetter):\qxldod\w10\amd64" -Recurse -ForceUnsigned

        Write-Log "  Adding driver 'vioinput'..."
        Add-WindowsDriver -Path $mountPath -Driver "$($VirtioDriveLetter):\vioinput\w10\amd64" -Recurse -ForceUnsigned

        Write-Log "  Adding driver 'viorng'..."
        Add-WindowsDriver -Path $mountPath -Driver "$($VirtioDriveLetter):\viorng\w10\amd64" -Recurse -ForceUnsigned

        Write-Log "  Adding driver 'vioserial'..."
        Add-WindowsDriver -Path $mountPath -Driver "$($VirtioDriveLetter):\vioserial\w10\amd64" -Recurse -ForceUnsigned

        Write-Log "  Adding driver 'viostor'..."
        Add-WindowsDriver -Path $mountPath -Driver "$($VirtioDriveLetter):\viostor\w10\amd64" -Recurse -ForceUnsigned
    }
}



#
# Main
#


With-IsoImage -IsoFileName $VirtioIsoPath {
    Param($virtioDriveLetter)

    $virtioInstaller = "$($virtioDriveLetter):\virtio-win-gt-x64.msi"
    $exists = Test-Path $virtioInstaller
    if (-not $exists) {
        throw 'The specified ISO does not appear to be a valid Virtio installation media.'
    }

    Write-Log "Add: $ImagePath with index: $ImageIndex and drive letter: $virtioDriveLetter"
    Add-DriversToWindowsImage -ImagePath $ImagePath -ImageIndex $ImageIndex -VirtioDriveLetter $virtioDriveLetter
}
