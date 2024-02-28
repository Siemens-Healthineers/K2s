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
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
&$PSScriptRoot\..\common\GlobalVariables.ps1
. $PSScriptRoot\..\common\GlobalFunctions.ps1

$setupInfoModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.cluster.module\setupinfo\setupinfo.module.psm1"
$runningStateModule = "$PSScriptRoot\..\status\RunningState.module.psm1"
$logModule = "$PSScriptRoot\..\ps-modules\log\log.module.psm1"
$infraModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"

Import-Module $setupInfoModule, $runningStateModule, $logModule, $infraModule -DisableNameChecking

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

$setupInfo = Get-SetupInfo

if ($setupInfo.LinuxOnly) {
    $errMsg = 'Resetting WinContainerStorage for linux-only setup is not supported!'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

if ($setupInfo.Name -eq $global:SetupType_MultiVMK8s -and !$setupInfo.LinuxOnly) {
    $errMsg = 'In order to clean up WinContainerStorage for multi-vm, please reinstall multi-vm cluster!'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

if ($setupInfo.Name -eq $global:SetupType_k2s) {
    $clusterState = Get-RunningState -SetupType $setupInfo.Name

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
    $errMsg = 'Docker daemon is running. Please stop docker daemon before performing this operation.'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code 'docker-running' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
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

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}