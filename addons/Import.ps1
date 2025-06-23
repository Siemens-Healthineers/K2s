# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
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
$addonsModule = "$PSScriptRoot\addons.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule

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

Write-Log "Extracting $ZipFile" -Console
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
        $foundAddons = $null
        $foundAddons = $exportedAddons | Where-Object { $_.name -match $name }

        if ($null -eq $foundAddons) {
            Remove-Item -Force $(Split-Path -Path "$extractionFolder" -Parent) -Recurse -Confirm:$False -ErrorAction SilentlyContinue
            $errMsg = "Addon `'$name`' not found in zip package for import!"
            if ($EncodeStructuredOutput -eq $true) {
                $err = New-Error -Code (Get-ErrCodeAddonNotFound) -Message $errMsg
                Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                return
            }
                    
            Write-Log $errMsg -Error
            exit 1
        }

        $addonsToImport += $foundAddons
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

     # # Define source and destination paths
    # $sourcePath = Join-Path -Path $extractionFolder -ChildPath "$($addon.dirName)\Content\*"
    # $destinationPath = Join-Path -Path "$PSScriptRoot\..\addons" -ChildPath $addon.name

    # Write-Log "Value of  sourcePath : $($sourcePath)"
    # Write-Log "Value of  destinationPath : $($destinationPath)"

    # # Ensure the destination directory exists
    # New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null    

    # # Copy only the contents of Content\ into the destination
    # Copy-Item -Path $sourcePath -Destination $destinationPath -Recurse -Force
 #---------------------
    # # Extract directory name from addon.dirName (e.g., "logging")
    # $dirName = $addon.name

    # # Define source path — where "Content" folder lives inside the extracted addon directory
    # $dirPath = Join-Path -Path $extractionFolder -ChildPath "$($addon.dirName)\Content"

    # # Define destination path — where contents should be copied
    # $destinationPath = Join-Path -Path "$PSScriptRoot\..\addons" -ChildPath "$dirName"

    # Write-Log "Value of dirPath (source): $dirPath"
    # Write-Log "Value of destinationPath : $destinationPath"
    
    # # TO DO : Split the destination path and create a directory under by name first string and create another directory using second string and then copy the content there.
    # # Value of destinationPath : C:\ws\k2slatest\K2s\addons\..\addons\ingress nginx

    # # Ensure destination exists and is a directory
    # if (-not (Test-Path $destinationPath)) {
    #     New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
    # }

    # # Copy only contents of Content (not the Content folder itself)
    # Copy-Item -Path (Join-Path $dirPath '*') -Destination $destinationPath -Recurse -Force
    #-----------------------------------------------------------------------------------

    # Begin another version

            # Split addon name (e.g., "ingress nginx" → ["ingress", "nginx"])
        $folderParts = $addon.name -split '\s+'

        # Start with base addons folder
        $destinationPath = Join-Path -Path $PSScriptRoot -ChildPath "..\addons"

        # Build full nested destination path
        foreach ($part in $folderParts) {
            $destinationPath = Join-Path -Path $destinationPath -ChildPath $part
        }

        # Define source path (Content folder)
        $dirPath = Join-Path -Path $extractionFolder -ChildPath "$($addon.dirName)\Content"

        # Log
        Write-Log "Value of dirPath (source): $dirPath"
        Write-Log "Value of destinationPath : $destinationPath"

        # Ensure final destination exists
        if (-not (Test-Path $destinationPath)) {
            New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
        }

        # Copy *only the contents* of Content (not the Content folder itself)
        Copy-Item -Path (Join-Path $dirPath '*') -Destination $destinationPath -Recurse -Force

    # End another version
    #---------------------------------------------------------------------------------


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