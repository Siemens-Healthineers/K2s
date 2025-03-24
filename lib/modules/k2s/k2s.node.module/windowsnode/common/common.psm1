# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

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
        [switch]$IgnoreErrors = $false
    )

    Write-Log "Copying '$Source' to '$Target', ignoring errors: '$IgnoreErrors'"

    $remoteComputerUser = "$UserName@$IpAddress"

    # Compress the source files into a zip archive
    $tempZip = "$env:TEMP\copy.zip"
    Compress-Archive -Path $Source -DestinationPath $tempZip -Force
    Write-Log "Compressed files into $tempZip"

    # Copy the zip file to the remote machine
    $output = scp.exe -o StrictHostKeyChecking=no -i $key "$tempZip" "${remoteComputerUser}:C:\Temp\copy.zip" 2>&1
    if ($LASTEXITCODE -ne 0 -and !$IgnoreErrors) {
        throw "Could not copy '$Source' to '$Target': $output"
    }
    Write-Log $output

    # Extract the zip file on the remote machine
    $extractCmd = "Expand-Archive -Path C:\Temp\copy.zip -DestinationPath $Target -Force"
    Invoke-CmdOnVmViaSSHKey -CmdToExecute $extractCmd -IpAddress $IpAddress -UserName $UserName
    Write-Log "Extracted files to $Target on remote machine"

    # Clean up temporary files
    $cleanupCmd = "Remove-Item -Path C:\Temp\copy.zip -Force"
    Invoke-CmdOnVmViaSSHKey -CmdToExecute $cleanupCmd -IpAddress $IpAddress -UserName $UserName
    Write-Log "Cleaned up temporary files on remote machine"

    Remove-Item -Path $tempZip -Force -ErrorAction SilentlyContinue
    Write-Log "Cleaned up temporary files on local machine"
}

Export-ModuleMember -Function Copy-ToRemoteComputerViaSshKey