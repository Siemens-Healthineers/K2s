# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
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
    [switch] $ShowLogs = $false
)


# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\..\common\GlobalFunctions.ps1

$setupTypeModule = "$PSScriptRoot\..\status\SetupType.module.psm1"
$runningStateModule = "$PSScriptRoot\..\status\RunningState.module.psm1"
$logModule = "$PSScriptRoot\..\ps-modules\log\log.module.psm1"
Import-Module $setupTypeModule, $runningStateModule, $logModule -DisableNameChecking

Initialize-Logging -ShowLogs:$ShowLogs

function Get-DockerStatus() {
    if (Get-Process 'dockerd' -ErrorAction SilentlyContinue) {
        return $true
    }
    return $false
}

function Perform-CleanupOfContainerStorage([string]$Directory, [int]$MaxRetries, [bool]$ForceZap) {
    $successfulDirectoryCleanup = $false
    for ($i = 0; $i -lt $MaxRetries; $i++) {
        &$PSScriptRoot\CleanupContainerStorage.ps1 -Directory $Directory
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
            &$global:BinPath\zap.exe -folder $Directory
            if (Test-Path $Directory) {
                Write-Error "Directory $Directory could not be successfully deleted. Please try again."
            }
            else {
                Write-Log "Directory $Directory cleaned up successfully." -Console
            }
        }
        else {
            Write-Error "Directory $Directory could not be successfully deleted. Please try again."
        }
    }
}

$setupType = Get-SetupType

if ($setupType.Name -eq $global:SetupType_MultiVMK8s) {
    return (Write-Error 'In order to clean up WinContainerStorage for multi-vm, please reinstall the cluster!')
}

if ($setupType.Name -eq $global:SetupType_k2s) {
    $clusterState = Get-RunningState -SetupType $setupType.Name

    if ($clusterState.IsRunning -eq $true) {
        throw 'K2s is running. Please stop K2s before performing this operation. Please ensure that no workloads are running in K2s..'
    }
}

$dockerRunningStatus = Get-DockerStatus
if ($dockerRunningStatus) {
    return (Write-Error 'Docker daemon is running. Please stop docker daemon before performing this operation.')
}

$cleanUpWasPerformed = $false
if (Test-Path $Containerd) {
    Write-Log "Performing cleanup of $Containerd" -Console
    Perform-CleanupOfContainerStorage -Directory $Containerd -MaxRetries $MaxRetries -ForceZap $ForceZap
    $cleanUpWasPerformed = $true
}

if (Test-Path $Docker) {
    Write-Log "Performing cleanup of $Docker" -Console
    Perform-CleanupOfContainerStorage -Directory $Docker -MaxRetries $MaxRetries -ForceZap $ForceZap
    $cleanUpWasPerformed = $true
}

if ($cleanUpWasPerformed) {
    Write-Log 'Done. Windows node container storage is reset.' -Console
}
else {
    Write-Log 'Done. Nothing to reset.' -Console
}