# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ImgDir,

    [Parameter(Mandatory = $true)]
    [string]$WinEdition,

    [Parameter(Mandatory = $true)]
    [string]$ComputerName,

    [string]$VHDXPath,

    [Parameter(Mandatory = $true)]
    [uint64]$VMVHDXSizeInBytes,

    [Parameter(Mandatory = $true)]
    [string]$AdminPwd,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Server2019Datacenter', 'Server2019Standard', 'Server2016Datacenter', 'Server2016Standard', 'Windows10Enterprise', 'Windows10Professional', 'Windows81Professional')]
    [string]$Version,

    [string]$Locale = 'en-US',

    [string]$AddVirtioDrivers,

    [ValidateNotNullOrEmpty()]
    [ValidateSet('BIOS', 'UEFI', 'WindowsToGo')]
    [string]$DiskLayout = 'UEFI'
)

$ErrorActionPreference = 'Stop'

# load global settings
&$PSScriptRoot\..\GlobalVariables.ps1
Import-Module "$PSScriptRoot\..\..\ps-modules\log\log.module.psm1"

if (-not $VHDXPath) {
    # https://stackoverflow.com/a/3040982
    $VHDXPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(".\$($ComputerName).vhdx")
}

# Source: https://docs.microsoft.com/en-us/windows-server/get-started/kmsclientkeys
$key = @{
    'Server2019Datacenter'     = 'WMDGN-G9PQG-XVVXX-R3X43-63DFG'
    'Server2019Standard'       = 'N69G4-B89J2-4G8F4-WWYCC-J464C'
    'Server2016Datacenter'     = 'CB7KF-BWN84-R7R2Y-793K2-8XDDG'
    'Server2016Standard'       = 'WC2BQ-8NRM3-FDDYY-2BFGV-KHKQY'
    'Windows10Enterprise'      = 'NPPR9-FWDCX-D2C8J-H872K-2YT43'
    'Windows11Enterprise'      = 'NPPR9-FWDCX-D2C8J-H872K-2YT43'
    'Windows10Professional'    = 'W269N-WFGWX-YVC9B-4J6C9-T83GX'
    'Windows11Professional'    = 'W269N-WFGWX-YVC9B-4J6C9-T83GX'
    'Windows81Professional'    = 'GCRJD-8NW9H-F2CDX-CCM8D-9D6T9'
}[$Version]

# Create unattend.xml
$unattendPath = $(&"$global:KubernetesPath\smallsetup\common\vmtools\New-WinUnattendFile.ps1" -AdminPwd $AdminPwd -WinVersionKey $key -VMName $ComputerName -Locale $Locale)

# Create VHDX from ISO image
Write-Log "Creating VHDX from image from $unattendPath"
. "$global:KubernetesPath\smallsetup\common\vmtools\Convert-WinImage.ps1"
Convert-WinImage -IsoPath $ImgDir -WinEdition $WinEdition -VHDPath $vhdxPath -SizeBytes $VMVHDXSizeInBytes -DiskLayout $DiskLayout -UnattendDir $unattendPath

if ($AddVirtioDrivers) {
    Write-Log "Adding Virtio Drivers from $AddVirtioDrivers"
    &"$global:KubernetesPath\smallsetup\common\vmtools\Add-VirtioDrivers.ps1" -VirtioIsoPath $AddVirtioDrivers -ImagePath $VHDXPath
}

$VHDXPath
