# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

# Import.ps1

<#
.Description
Import image from oci tar archive
#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false)]
    [string] $ZipFile,
    [parameter(Mandatory = $false, HelpMessage = 'Name of Addons to import')]
    [string[]] $Names
)

# load global settings
&$PSScriptRoot\..\smallsetup\common\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\..\smallsetup\common\GlobalFunctions.ps1

Import-Module "$PSScriptRoot\..\lib\modules\k2s\k2s.cluster.module\setupinfo\setupinfo.module.psm1"
Import-Module $PSScriptRoot\..\smallsetup\status\RunningState.module.psm1
Import-Module $PSScriptRoot\..\smallsetup\ps-modules\log\log.module.psm1
Initialize-Logging -ShowLogs:$ShowLogs

$setupInfo = Get-SetupInfo
if ($setupInfo.ValidationError) {
    throw $setupInfo.ValidationError
}

$clusterState = Get-RunningState -SetupType $setupInfo.Name

if ($clusterState.IsRunning -ne $true) {
    throw "Cannot import addons when system is not running. Please start the system with 'k2s start'."
}

Write-Log 'Extracting images' -Console
Write-Log '---' -Console
$dir = Split-Path $ZipFile
$extractionFolder = "${dir}\addons"
Remove-Item -Force "${extractionFolder}" -Recurse -Confirm:$False -ErrorAction SilentlyContinue
Expand-Archive $ZipFile -DestinationPath $dir -Force

$exportedAddons = (Get-Content "$extractionFolder\addons.json" | Out-String | ConvertFrom-Json).addons
if ($null -eq $exportedAddons -or $exportedAddons.Count -lt 1) {
    Write-Error 'Invalid format for addon import!'
    exit 1
}

$addonsToImport = @()
if ($Names.Count -gt 0) {
    foreach ($name in $Names) {
        $foundAddon = $null

        foreach ($addon in $exportedAddons) {
            if ($addon.name -eq $name) {
                $foundAddon = $addon
                break
            }
        }

        if ($null -eq $foundAddon) {
            Remove-Item -Force "$extractionFolder" -Recurse -Confirm:$False -ErrorAction SilentlyContinue
            throw "Addon `'$name`' not found in zip package for import!"
        }

        $addonsToImport += $foundAddon
    }
}
else {
    $addonsToImport = $exportedAddons
}

foreach ($addon in $addonsToImport) {
    $images = @()
    $files = Get-Childitem -recurse "${extractionFolder}\$($addon.dirName)" | Where-Object { $_.Name -match '.*.tar' } | ForEach-Object { $_.Fullname }
    $images += $files
    Write-Log "Importing images from ${extractionFolder}\$($addon.dirName) for addon $($addon.name)" -Console

    foreach ($image in $images) {
        if ($image.Contains('_win')) {
            if (!$setupInfo.LinuxOnly) {
                &$global:KubernetesPath\smallsetup\helpers\ImportImage.ps1 -Windows -ImagePath $image -ShowLogs:$ShowLogs
            }
        }
        else {
            &$global:KubernetesPath\smallsetup\helpers\ImportImage.ps1 -ImagePath $image -ShowLogs:$ShowLogs
        }
    }

    if ($null -ne $addon.offline_usage) {
        Write-Log '---'
        Write-Log "Importing and installing packages for addon $($addon.name)" -Console
        $linuxPackages = $addon.offline_usage.linux
        $linuxCurlPackages = $linuxPackages.curl
        $windowsPackages = $addon.offline_usage.windows
        $windowsCurlPackages = $windowsPackages.curl

        # import and install debian packages
        if (Test-Path -Path "${extractionFolder}\$($addon.dirName)\debianpackages") {
            ExecCmdMaster "sudo rm -rf .$($addon.dirName)"
            ExecCmdMaster "mkdir -p .$($addon.dirName)"
            Copy-FromToMaster "${extractionFolder}\$($addon.dirName)\debianpackages\*" $($global:Remote_Master + ':' + ".$($addon.dirName)")
        }

        # import linux packages
        foreach ($package in $linuxCurlPackages) {
            $filename = ([uri]$package.url).Segments[-1]
            $destination = $package.destination
            Copy-FromToMaster "${extractionFolder}\$($addon.dirName)\linuxpackages\${filename}" $($global:Remote_Master + ':' + '/tmp')
            ExecCmdMaster "sudo cp /tmp/${filename} ${destination}"
            ExecCmdMaster "sudo rm -rf /tmp/${filename}"
        }
        ExecCmdMaster 'cd /tmp && sudo rm -rf linuxpackages'

        # import windows packages
        foreach ($package in $windowsCurlPackages) {
            $filename = ([uri]$package.url).Segments[-1]
            $destination = $package.destination
            $destinationFolder = Split-Path -Path "$PSScriptRoot\..\$destination"
            mkdir -Force $destinationFolder | Out-Null
            Copy-Item -Path "${extractionFolder}\$($addon.dirName)\windowspackages\${filename}" -Destination "$PSScriptRoot\..\$destination" -Force
        }
    }
    Write-Log '---' -Console
}

Remove-Item -Force "$extractionFolder" -Recurse -Confirm:$False -ErrorAction SilentlyContinue

Write-Log '---'
Write-Log "Addons '$($addonsToImport.name)' imported successfully!" -Console