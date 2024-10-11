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
$infraModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"

Import-Module $infraModule, $clusterModule

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

Write-Log 'Extracting images' -Console
Write-Log '---' -Console
$tmpDir = "$env:TEMP\$(Get-Date -Format ddMMyyyy-HHmmss)-tmp-extracted-addons"
$extractionFolder = "$tmpDir\addons"
Remove-Item -Force "${extractionFolder}" -Recurse -Confirm:$False -ErrorAction SilentlyContinue

# check if drive has enough space to extract the zip file
$zipSize = (Get-Item $ZipFile).length
$drive = (Get-Item $env:TEMP).PSDrive.Name
$freeSpace = (Get-PSDrive -Name $drive).Free
$freeSpaceGB = [math]::Round($freeSpace / 1GB, 2)
$zipSizeGB = [math]::Round($zipSize / 1GB, 2)
$additionalSpace = 2 * 1024 * 1024 * 1024 # 2 GB
Write-Log "Free space $freeSpaceGB GB, size of addons zip file: $zipSizeGB GB" -Console
if ($zipSize -gt ($freeSpace + $additionalSpace)) {
    $errMsg = "Not enough space on drive $drive to extract the zip file. Required space: $zipSize bytes, Free space: $freeSpace bytes."
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'image-space-insufficient' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
                    
    Write-Log $errMsg -Error
    exit 1
}
Expand-Archive $ZipFile -DestinationPath "$tmpDir" -Force

$exportedAddons = (Get-Content "$extractionFolder\addons.json" | Out-String | ConvertFrom-Json).addons
if ($null -eq $exportedAddons -or $exportedAddons.Count -lt 1) {
    $errMsg = 'Invalid format for addon import.'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'image-format-invalid' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
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
                $err = New-Error -Code (Get-ErrCodeAddonNotFound) -Message $errMsg
                Send-ToCli -MessageType $MessageType -Message @{Error = $err }
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
        $importImageScript = "$PSScriptRoot\..\lib\scripts\k2s\image\Import-Image.ps1"
        if ($image.Contains('_win')) {
            if (!$setupInfo.LinuxOnly) {
                &$importImageScript -Windows -ImagePath $image -ShowLogs:$ShowLogs
            }
        }
        else {
            &$importImageScript -ImagePath $image -ShowLogs:$ShowLogs
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
            (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo rm -rf .$($addon.dirName)").Output | Write-Log
            (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "mkdir -p .$($addon.dirName)").Output | Write-Log

            Copy-ToControlPlaneViaSSHKey -Source "${extractionFolder}\$($addon.dirName)\debianpackages\*" -Target ".$($addon.dirName)"
        }

        # import linux packages
        foreach ($package in $linuxCurlPackages) {
            $filename = ([uri]$package.url).Segments[-1]
            $destination = $package.destination
            Copy-ToControlPlaneViaSSHKey -Source "${extractionFolder}\$($addon.dirName)\linuxpackages\${filename}" -Target '/tmp'

            (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo cp /tmp/${filename} ${destination}").Output | Write-Log
            (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo rm -rf /tmp/${filename}").Output | Write-Log
        }
        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'cd /tmp && sudo rm -rf linuxpackages').Output | Write-Log

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

Remove-Item -Force "$tmpDir" -Recurse -Confirm:$False -ErrorAction SilentlyContinue

Write-Log '---'
Write-Log "Addons '$($addonsToImport.name)' imported successfully!" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}