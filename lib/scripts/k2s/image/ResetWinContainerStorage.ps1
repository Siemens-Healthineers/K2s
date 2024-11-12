# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
This script is used to clean the image storage of containerd and docker on the windows node.

.DESCRIPTION
If the cluster is running, then the script expects the user to stop the cluster
The scripts then cleans the containerd and docker directories provided as script arguments.
It is available to remove all running workloads from the cluster before running this script.

Sometimes, it is not possible to clean the directories with a single execution. Hence, the
script also accepts the number of retries to be performed as an argument.

.EXAMPLE
PS> Clean up Containerd and Docker image storage on windows node with no retries
PS> .\ResetWinContainerStorage.ps1 -Containerd D:\containerd -Docker D:\docker
PS>
PS> Clean up Containerd and Docker image storage on windows node with 5 retries
PS> .\ResetWinContainerStorage.ps1 -Containerd D:\containerd -Docker D:\docker -MaxRetries 5
#>

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Containerd directory')]
    [string]$Containerd = 'C:\containerd1',
    [parameter(Mandatory = $false, HelpMessage = 'Docker directory')]
    [string]$Docker = 'C:\docker1',
    [parameter(Mandatory = $false, HelpMessage = 'Number of retries to be performed for deleting each directory')]
    [int]$MaxRetries = 1,
    [parameter(Mandatory = $false, HelpMessage = 'Use zap.exe to forcefully delete the folder')]
    [switch]$ForceZap = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType,
    [parameter(Mandatory = $false, HelpMessage = 'Trigger clean-up of windows container storage without user prompts')]
    [switch]$Force = $false
)
$infraModule = "$PSScriptRoot\..\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"

Import-Module $infraModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

function Get-DockerStatus() {
    if (Get-Process 'dockerd' -ErrorAction SilentlyContinue) {
        return $true
    }
    return $false
}

<#
.SYNOPSIS
Cleanup docker storage directory 

.DESCRIPTION
Cleanup docker storage directory  from all reparse points which could lead to an inconsistent system.
Allso delete the whole folder afterwards.

# Only for docker: Cleanup in the docker way by renaming the folders
# Get-ChildItem -Path d:\docker\windowsfilter -Directory | % {Rename-Item $_.FullName "$($_.FullName)-removing" -ErrorAction:SilentlyContinue}
# Restart-Service *docker*
# needs to be done multiple times till all directories from windowsfilter are deleted !!

# OR

# 1. set right to be able to delete reparse points
# 2. icacls "D:\containerdold" /grant Administrators:F /t /C
# 3. Get-ChildItem -Path e:\docker_old3 -Force -Recurse -Attributes Reparsepoint -ErrorAction 'silentlycontinue' | % { $n = $_.FullName.Trim("\"); fsutil reparsepoint delete "$n" }
# deletes all reparse points
# then afterwards all directories can be deleted
# 4. takeown /a /r /d Y /f e:\docker_old3
# 5. remove-item -path "e:\docker_old3" -Force -Recurse -ErrorAction SilentlyContinue

.EXAMPLE
Invoke-GracefulCleanup -Directory d:\docker
Invoke-GracefulCleanup -Directory d:\containerd
#>
function Invoke-GracefulCleanup {
    param (
        [parameter(Mandatory = $false, HelpMessage = 'Docker directory to clean up')]
        [string] $Directory = 'c:\docker'
    )
    $errActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    if ($Trace) {
        Set-PSDebug -Trace 1
    }

    Write-Log "Take ownership now on items in dir: $Directory" -Console
    takeown /a /r /d Y /F $Directory 2>&1 | Write-Log -Console

    Write-Log 'Add ownership also for Administrators' -Console
    icacls $Directory /grant Administrators:F /t /C 2>&1 | Write-Log -Console

    Write-Log "Delete reparse points in the directory: $Directory" -Console
    Get-ChildItem -Path $Directory -Force -Recurse -Attributes Reparsepoint -ErrorAction SilentlyContinue | ForEach-Object { $n = $_.FullName.Trim('\'); fsutil reparsepoint delete "$n" 2>&1 | Write-Log -Console }

    Write-Log "Remove items from: $Directory" -Console
    Remove-Item -Path $Directory -Force -Recurse -ErrorAction SilentlyContinue

    Write-Log 'Cleanup finished' -Console

    $ErrorActionPreference = $errActionPreference
}

function Invoke-CleanupOfContainerStorage([string]$Directory, [int]$MaxRetries, [bool]$ForceZap) {
    $successfulDirectoryCleanup = $false
    for ($i = 0; $i -lt $MaxRetries; $i++) {
        Invoke-GracefulCleanup -Directory $Directory
        if (Test-Path $Directory) {
            Write-Log "Directory $Directory could not be successfully deleted. Will retry again..." -Console
        }
        else {
            Write-Log "Directory $Directory cleaned up successfully." -Console
            $successfulDirectoryCleanup = $true
            break
        }
    }
    if (!$successfulDirectoryCleanup) {
        if ($ForceZap) {
            Write-Log 'Directory could not be cleaned up after exhausting all retries. Will zap it using zap.exe' -Console
            &"$(Get-KubeBinPath)\zap.exe" -folder $Directory 2>&1 | Write-Log
            if (Test-Path $Directory) {
                Write-Log "Directory $Directory could not be successfully deleted. Please try again." -Error
            }
            else {
                Write-Log "Directory $Directory cleaned up successfully." -Console
            }
        }
        else {
            Write-Log "Directory $Directory could not be successfully deleted. Please try again." -Error
        }
    }
}

$setupInfo = Get-SetupInfo

if ($setupInfo.LinuxOnly) {
    $errMsg = 'Resetting WinContainerStorage for Linux-only setup is not supported.'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

if ($setupInfo.Name -eq 'MultiVMK8s' -and !$setupInfo.LinuxOnly) {
    $errMsg = 'In order to clean up Win container storage for multivm setup, please re-install multivm cluster.'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

if ($setupInfo.Name -eq 'k2s') {
    $clusterState = Get-RunningState -SetupName $setupInfo.Name

    if ($clusterState.IsRunning -eq $true) {
        $errMsg = 'K2s is still running. Please stop K2s before performing this operation. Please ensure that no workloads are running in K2s.'
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code (Get-ErrCodeSystemRunning) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1      
    }
}

$dockerRunningStatus = Get-DockerStatus
if ($dockerRunningStatus) {
    $errMsg = 'Docker daemon is running. Please stop Docker daemon before performing this operation.'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code 'docker-running' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

if (!$Force) {
    $answer = Read-Host "WARNING: Deletion of containerd/docker directory may take a very long time depending on the size of the folder and number of retries.`nContinue? (y/N)"
    if ($answer -ne 'y') {
        $msg = 'Resetting Windows container storage cancelled.'

        if ($EncodeStructuredOutput -eq $true) {            
            $err = New-Error -Severity Warning -Code (Get-ErrCodeUserCancellation) -Message $msg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $msg -Console
        exit 0
    }
}

$cleanUpWasPerformed = $false
if (Test-Path $Containerd) {
    Write-Log "Performing cleanup of $Containerd" -Console
    Invoke-CleanupOfContainerStorage -Directory $Containerd -MaxRetries $MaxRetries -ForceZap $ForceZap
    $cleanUpWasPerformed = $true
}

if (Test-Path $Docker) {
    Write-Log "Performing cleanup of $Docker" -Console
    Invoke-CleanupOfContainerStorage -Directory $Docker -MaxRetries $MaxRetries -ForceZap $ForceZap
    $cleanUpWasPerformed = $true
}

if ($cleanUpWasPerformed) {
    Write-Log 'Done. Windows node container storage is reset.' -Console
}
else {
    Write-Log 'Done. Nothing to reset.' -Console
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}