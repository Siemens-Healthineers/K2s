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
    [string[]] $Names,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
&$PSScriptRoot\..\smallsetup\common\GlobalVariables.ps1
. $PSScriptRoot\..\smallsetup\common\GlobalFunctions.ps1

$statusModule = "$PSScriptRoot/../lib/modules/k2s/k2s.cluster.module/status/status.module.psm1"
$cliMessagesModule = "$PSScriptRoot/../lib/modules/k2s/k2s.infra.module/cli-messages/cli-messages.module.psm1"
$logModule = "$PSScriptRoot\..\smallsetup\ps-modules\log\log.module.psm1"

Import-Module $logModule, $cliMessagesModule, $statusModule

Initialize-Logging -ShowLogs:$ShowLogs

$systemError = Test-SystemAvailability
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError -Error
    exit 1
}

Write-Log 'Extracting images' -Console
Write-Log '---' -Console
$dir = Split-Path $ZipFile
$extractionFolder = "${dir}\tmp-extracted-addons\addons"
Remove-Item -Force "${extractionFolder}" -Recurse -Confirm:$False -ErrorAction SilentlyContinue
Expand-Archive $ZipFile -DestinationPath "$dir\tmp-extracted-addons" -Force

$exportedAddons = (Get-Content "$extractionFolder\addons.json" | Out-String | ConvertFrom-Json).addons
if ($null -eq $exportedAddons -or $exportedAddons.Count -lt 1) {
    $errMsg = 'Invalid format for addon import!'
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $errMsg }
        return
    }
                    
    Write-Log $errMsg -Error
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
            $errMsg = "Addon `'$name`' not found in zip package for import!"
            if ($EncodeStructuredOutput -eq $true) {
                Send-ToCli -MessageType $MessageType -Message @{Error = $errMsg }
                return
            }
                    
            Write-Log $errMsg -Error
            exit 1
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

Remove-Item -Force "${dir}\tmp-extracted-addons" -Recurse -Confirm:$False -ErrorAction SilentlyContinue

Write-Log '---'
Write-Log "Addons '$($addonsToImport.name)' imported successfully!" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}