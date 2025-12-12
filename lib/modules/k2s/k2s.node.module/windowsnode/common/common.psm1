# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
# SPDX-License-Identifier: MIT
$configModule = "$PSScriptRoot\..\..\..\k2s.infra.module\config\config.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\k2s.infra.module\log\log.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\k2s.infra.module\path\path.module.psm1"
Import-Module $configModule, $pathModule, $logModule

$key = Get-SSHKeyControlPlane

function Copy-ToRemoteComputerViaSshKeyWindows {
    Param(
        [Parameter(Mandatory = $true, HelpMessage = 'Source path of the files to copy')]
        [string]$Source,
        [Parameter(Mandatory = $true, HelpMessage = 'Target path on the remote machine')]
        [string]$Target,
        [Parameter(Mandatory = $true, HelpMessage = 'Username for the remote machine')]
        [string]$UserName,
        [Parameter(Mandatory = $true, HelpMessage = 'IP address of the remote machine')]
        [string]$IpAddress,
        [Parameter(Mandatory = $false, HelpMessage = 'Ignore errors during the copy process')]
        [switch]$IgnoreErrors = $false,
        [Parameter(Mandatory = $false, HelpMessage = 'File extensions to exclude (comma-separated)')]
        [string]$ExcludeExtensions = '.vhdx'
    )

    Write-Log "Copying '$Source' to '$Target', ignoring errors: '$IgnoreErrors', excluding extensions: '$ExcludeExtensions'"

    $remoteComputerUser = "$UserName@$IpAddress"

    # Parse the exclude extensions into an array
    $excludeExtensionsArray = $ExcludeExtensions -split ',' | ForEach-Object { $_.Trim() }

    # Create a temporary folder to store filtered files
    $tempFilteredFolder = "$env:TEMP\FilteredFiles"
    if (Test-Path $tempFilteredFolder) {
        Remove-Item -Path $tempFilteredFolder -Recurse -Force
    }
    New-Item -ItemType Directory -Path $tempFilteredFolder | Out-Null

    #Copy all files except the excluded extensions to the temporary folder
    Get-ChildItem -Path $Source -Recurse | Where-Object { $excludeExtensionsArray -notcontains $_.Extension } | ForEach-Object {
        $relativePath = $_.FullName.Substring($Source.Length).TrimStart('\')
        $destinationPath = Join-Path -Path $tempFilteredFolder -ChildPath $relativePath
        $destinationDir = Split-Path -Path $destinationPath
        if (!(Test-Path $destinationDir)) {
            New-Item -ItemType Directory -Path $destinationDir | Out-Null
        }
        Copy-Item -Path $_.FullName -Destination $destinationPath
    }
    Write-Log "Filtered files copied to temporary folder: $tempFilteredFolder"

    # Compress the filtered files into a zip archive
    $tempZip = "$env:TEMP\copy.zip"
    Compress-Archive -Path "$tempFilteredFolder\*" -DestinationPath $tempZip -Force
    Write-Log "Compressed files into $tempZip"

    # Check if the C:\Temp\ folder exists on the remote machine
$checkFolderCmd = "Test-Path -Path 'C:\Temp'"
$folderExists = Invoke-PowerShellOnVmViaSSHKey -CmdToExecute $checkFolderCmd -IpAddress $IpAddress -UserName $UserName

if ($folderExists.Output -eq "False") {
    # Create the C:\Temp\ folder on the remote machine
    $createFolderCmd = "New-Item -ItemType Directory -Path 'C:\Temp' -Force"
    Invoke-PowerShellOnVmViaSSHKey -CmdToExecute $createFolderCmd -IpAddress $IpAddress -UserName $UserName
    Write-Log "Created C:\Temp\ on the remote machine"
} else {
    Write-Log "C:\Temp\ already exists on the remote machine"
}

    # Copy the zip file to the remote machine
    $output = scp.exe -o StrictHostKeyChecking=no -i $key "$tempZip" "${remoteComputerUser}:C:\Temp\copy.zip" 2>&1
    if ($LASTEXITCODE -ne 0 -and !$IgnoreErrors) {
        throw "Could not copy '$Source' to '$Target': $output"
    }
    Write-Log $output

    # Extract the zip file on the remote machine
    $extractCmd = "Expand-Archive -Path C:\Temp\copy.zip -DestinationPath $Target -Force"
    Invoke-PowerShellOnVmViaSSHKey -CmdToExecute $extractCmd -IpAddress $IpAddress -UserName $UserName
    Write-Log "Extracted files to $Target on remote machine"

    # Clean up temporary files
    $cleanupCmd = "Remove-Item -Path C:\Temp\copy.zip -Force"
    Invoke-PowerShellOnVmViaSSHKey -CmdToExecute $cleanupCmd -IpAddress $IpAddress -UserName $UserName
    Write-Log "Cleaned up temporary files on remote machine"

    Remove-Item -Path $tempZip -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $tempFilteredFolder -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "Cleaned up temporary files on local machine"
}

Export-ModuleMember -Function Copy-ToRemoteComputerViaSshKeyWindows