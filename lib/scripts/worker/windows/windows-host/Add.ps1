Param(
    [string] $UserName = $(throw 'Argument missing: UserName'),
    [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
    [string] $NodeName,
    [string] $WindowsHostIpAddress = '',
    [string] $Proxy = '',
    [switch] $ShowLogs = $false
)

$durationStopwatch = [system.diagnostics.stopwatch]::StartNew()

$infraModule =   "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule =    "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

$ErrorActionPreference = 'Stop'

# Set installation path
$installationPath = Get-KubePath
Set-Location $installationPath

# Pre-requisites check
Write-Log "Performing pre-requisites check windows" -Console

$connectionCheck = (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'powershell.exe -Command "Get-Command"' -UserName $UserName -IpAddress $IpAddress)
if (!$connectionCheck.Success) {
    throw "Cannot connect to node with IP '$IpAddress'. Error message: $($connectionCheck.Output)"
}

# Public key check
$localPublicKeyFilePath = "$(Get-SSHKeyControlPlane).pub"
if (!(Test-Path -Path $localPublicKeyFilePath)) {
    throw "Precondition not met: the file '$localPublicKeyFilePath' shall exist."
}
$localPublicKey = (Get-Content -Raw $localPublicKeyFilePath).Trim()
if ([string]::IsNullOrWhiteSpace($localPublicKey)) {
    throw "Precondition not met: the file '$localPublicKeyFilePath' is not empty."
}
$authorizedKeysFilePath = "C:\ProgramData\ssh\administrators_authorized_keys"

$authorizedKeys = (Invoke-CmdOnVmViaSSHKey -CmdToExecute "powershell.exe Get-Content $authorizedKeysFilePath" -UserName $UserName -IpAddress $IpAddress).Output
if (!($authorizedKeys.Contains($localPublicKey))) {
    throw "Precondition not met: the local public key from the file '$localPublicKeyFilePath' is present in the file '$authorizedKeysFilePath' of the computer with IP '$IpAddress'."
}

# Hostname check
$actualHostname = (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'powershell.exe -Command "hostname"' -UserName $UserName -IpAddress $IpAddress).Output.Trim()

$k8sFormattedNodeName = $actualHostname.ToLower()

if (![string]::IsNullOrWhiteSpace($NodeName) -and ($NodeName.ToLower() -ne $k8sFormattedNodeName)) {
    throw "Precondition not met: the passed NodeName '$NodeName' is the hostname of the computer with IP '$IpAddress' ($actualHostname)"
}

$NodeName = $actualHostname

$clusterState = (Invoke-Kubectl -Params @('get', 'nodes', '-o', 'wide')).Output
if ($clusterState -match $k8sFormattedNodeName) {
    throw "Precondition not met: the node '$k8sFormattedNodeName' is already part of the cluster."
}

#Define paths
$key = Get-SSHKeyControlPlane
$sourcePath = "C:\K2s"
$zipFilePath = "C:\K2s\windowsnode.zip"
$remoteZipPath = "C:\Temp\windowsnode.zip"
$extractPath = "C:\k2s"


# Check if the zip file already exists
if (-not (Test-Path $zipFilePath)) {
    Write-Host "Creating zip file: $zipFilePath"

       # Create a temp directory named 'bin' in temp
    $tempDir = Join-Path $env:TEMP "k2s_temp_$(Get-Random)"
    $tempBin = Join-Path $tempDir "bin"
    New-Item -ItemType Directory -Path $tempBin -Force | Out-Null

    # Copy bin contents excluding .vhdx
    Copy-Item "$sourcePath\bin\*" $tempBin -Recurse -Exclude *.vhdx

    # Create the zip file for the first time
    Compress-Archive -Path "$sourcePath\cfg", "$sourcePath\lib", $tempBin, "$sourcePath\VERSION", "$sourcePath\smallsetup" -DestinationPath $zipFilePath -Force
    
    # Clean up temp directory
    Remove-Item $tempDir -Recurse -Force
    
    Write-Host "Zip file created: $zipFilePath"
} else {
    Write-Host "Zip file already exists: $zipFilePath"
}

$result = Invoke-CmdOnVmViaSSHKey -CmdToExecute 'cmd /c "if not exist C:\Temp mkdir C:\Temp"' -UserName $UserName -IpAddress $IpAddress
if (-not $result.Success) {
    throw "Remote command failed: $($result.Output)"
}

# Copy the zip file to the remote machine
Write-Host "Copying zip file to the remote machine: $remoteZipPath"
scp.exe -o StrictHostKeyChecking=no -i $key "$zipFilePath" "${UserName}@${IpAddress}:$remoteZipPath"

# Extract the zip file on the remote machine
Write-Host "Extracting zip file on the remote machine: $extractPath"
$extractCmd = "powershell -Command `"Expand-Archive -Path '$remoteZipPath' -DestinationPath '$extractPath' -Force`""
Invoke-CmdOnVmViaSSHKey -CmdToExecute $extractCmd -IpAddress $IpAddress -UserName $UserName

# Copy the corrected InstallNode.ps1 file to override the one from the zip
Write-Host "Copying corrected InstallNode.ps1 to remote machine"
$localInstallNodeScript = "$PSScriptRoot\InstallNode.ps1"
$remoteInstallNodeScript = "C:\k2s\lib\scripts\worker\windows\windows-host\InstallNode.ps1"
scp.exe -o StrictHostKeyChecking=no -i $key "$localInstallNodeScript" "${UserName}@${IpAddress}:$remoteInstallNodeScript"

# Generate join command locally
Write-Host "Generating join command for the cluster"
$JoinCommand = New-JoinCommand
Write-Host "Join command generated: $JoinCommand"

# Write join command to a temporary file
$joinCommandFile = "$env:TEMP\join-command.txt"
Set-Content -Path $joinCommandFile -Value $JoinCommand -Encoding UTF8

# Copy the join command file to the remote machine
$remoteJoinCommandFile = "C:\Temp\join-command.txt"
Write-Host "Copying join command file to remote machine"
scp.exe -o StrictHostKeyChecking=no -i $key "$joinCommandFile" "${UserName}@${IpAddress}:$remoteJoinCommandFile"

# Execute InstallNode.ps1 directly on the remote machine
Write-Host "Executing InstallNode.ps1 on remote machine: $IpAddress"
$executeScriptCmd = "powershell -ExecutionPolicy Bypass -File `"C:\k2s\lib\scripts\worker\windows\windows-host\InstallNode.ps1`" -ShowLogs -IpAddress $IpAddress"

$result = Invoke-CmdOnVmViaSSHKey -CmdToExecute $executeScriptCmd -IpAddress $IpAddress -UserName $UserName

# Simple error checking
if (-not $result.Success) {
    Write-Error "InstallNode.ps1 execution failed: $($result.Output)"
    throw "Remote installation failed"
}

