# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Dumps k2s system status to target folder

.DESCRIPTION
Dumps the k2s system status to target folder, gathering log and config files

.PARAMETER OpenDumpFolder
If set to $true, the dump target folder will be opened in Windows explorer afterwards. Default: $true

.EXAMPLE
PS> .\DumpSystemStatus.ps1

.EXAMPLE
PS> .\DumpSystemStatus.ps1 -OpenDumpFolder $false
#>

Param(
    [parameter(Mandatory = $false, HelpMessage = 'If set to $true, the dump target folder will be opened in Windows explorer. Default: $true')]
    [bool] $OpenDumpFolder = $true,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [bool] $ShowLogs,
    [parameter(Mandatory = $false, HelpMessage = 'File name of final dump file')]
    [string] $ZipFileName = ''
)

#################################################################################################
# FUNCTIONS                                                                                     #
#################################################################################################

function DumpNodeDetails($DumpTargetDir, $LinuxNodeState, $setupType) {
    #Get host details
    $dumpfile = Join-Path $DumpTargetDir "$(hostname)-node.txt"
    ([System.Environment]::OSVersion).ToString() > $dumpfile
    (Get-Item "HKLM:SOFTWARE\Microsoft\Windows NT\CurrentVersion").GetValue('DisplayVersion') >> $dumpfile

    if (Test-Path 'C:\Windows\System32\systeminfo.exe' -ErrorAction SilentlyContinue) {
        systeminfo.exe >> $dumpfile
    } else {
        $hotFix = Get-HotFix
        if ($null -ne $hotFix) {
            $hotFix >> $dumpfile
        }
        else {
            '<No hotfix>' >> $dumpfile
        }
    }

    # Get Linux node details
    if ($LinuxNodeState -eq [Microsoft.HyperV.PowerShell.VMState]::Running) {
        $kubeMasterDumpfile = Join-Path $DumpTargetDir "$($global:VMName)-node.txt"
        ExecCmdMaster 'uname -a' -NoLog >> $kubeMasterDumpfile
        ExecCmdMaster 'cat /proc/version' -NoLog >> $kubeMasterDumpfile
    }

    # Get additional node details for multi-vm
    if ($setupType -eq $global:SetupType_MultiVMK8s) {

        [string]$winWorkerNodeStatus = GetWinNodeStatus

        if ($winWorkerNodeStatus -eq [Microsoft.HyperV.PowerShell.VMState]::Running) {

            $multiVmFileName = "$($global:MultiVMWindowsVMName)"
            $mulitVMDumpFile = Join-Path $DumpTargetDir "$multiVmFileName.zip"
            $session = Open-RemoteSessionViaSSHKey $global:Admin_WinNode $global:WindowsVMKey

            $winWorkerNodeDumpFile = Join-Path "$env:SystemDrive\var\log" "$multiVmFileName.zip"
            Invoke-Command -Session $session -ScriptBlock {
                Set-Location "$env:SystemDrive\k"
                Set-ExecutionPolicy Bypass -Force -ErrorAction Continue

                &"$env:SystemDrive\k\smallsetup\debug\DumpSystemStatus.ps1" -OpenDumpFolder $false -ShowLogs $false -ZipFileName $using:multiVmFileName 2> $null
            }

            Write-Output "Multi-VM dump file name: $multiVmFileName"
            &"$global:KubernetesPath\smallsetup\helpers\scpw.ps1" -Source $winWorkerNodeDumpFile -Target $mulitVMDumpFile -Reverse
        }
    }
}

<#
.DESCRIPTION
    Returns the status of multi-vm windows worker node (Hyper-V based).

.OUTPUTS
    'Running' if the VM is in running state.
    '' if the VM is not found or stopped.
#>
function GetWinNodeStatus {
    $WinWorkerState = ''

    $vmStatus = Get-Vm -Name $global:MultiVMWindowsVMName -ErrorAction SilentlyContinue
    if ($vmStatus) {
        #Get the VM State
        $WinWorkerState = ($vmStatus.State).ToString()
    }

    if ($WinWorkerState -ne [Microsoft.HyperV.PowerShell.VMState]::Running) {
        Write-Log "Mult-VM Win node: $global:VMName based on Hyper-V VM is not running, will proceed with dump of host node.."
    }
    return $WinWorkerState
}

<#
.DESCRIPTION
    Returns the status of linux node (Hyper-V or WSL based).

.OUTPUTS
    'Running' if the VM is in running state.
    '' if the VM is not found or stopped.
#>
function GetLinuxNodeStatus {
    $KubeMasterState = ''

    $WSL = Get-WSLFromConfig
    if ($WSL) {
        if ($(wsl -l --running) -notcontains "KubeMaster (Default)") {
            Write-Log "Linux node: $global:VMName based on WSL Distro is not running, will proceed with dump of host node.."
        } else {
            $KubeMasterState = [Microsoft.HyperV.PowerShell.VMState]::Running
        }
    } else {

        $vmStatus = Get-Vm -Name $global:VMName -ErrorAction SilentlyContinue
        if ($vmStatus) {
            #Get the VM State
            $KubeMasterState = ($vmStatus.State).ToString()
        }

        if ($KubeMasterState -ne [Microsoft.HyperV.PowerShell.VMState]::Running) {
            Write-Log "Linux node: $global:VMName based on Hyper-V VM is not running, will proceed with dump of host node.."
        }
    }

    return $KubeMasterState
}

#################################################################################################
# SCRIPT START                                                                                  #
#################################################################################################


&$PSScriptRoot\..\common\GlobalVariables.ps1
. $PSScriptRoot\..\common\GlobalFunctions.ps1

$ErrorActionPreference = 'Stop'

if ($Trace) {
    Set-PSDebug -Trace 1
}

Import-Module "$PSScriptRoot/../ps-modules/log/log.module.psm1"
Initialize-Logging -ShowLogs:$ShowLogs


$logsDir = "$($global:SystemDriveLetter):\var\log"
$dumpTargetDir = $logsDir


Write-Log 'k2s system dump started' -Console

try {

    $dumpDirName = ''
    if ($ZipFileName -eq '') {
        $dumpDirName = "k2s-dump-$env:COMPUTERNAME-$(Get-Date -Format 'yyyyMMddTHHmmssfff')"
    } else {
        $dumpDirName = $ZipFileName
    }

    $parentTempDir = [System.IO.Path]::GetTempPath()
    $tempDir = Join-Path $parentTempDir $dumpDirName
    $tempLogsDir = Join-Path $tempDir 'logs'
    $tempConfigDir = Join-Path $tempDir 'config\'
    $tempNetworkDir = Join-Path $tempDir 'networking\'
    $hostInfoDir = Join-Path $tempDir 'node\'
    $dumpTargetPath = Join-Path $dumpTargetDir "$dumpDirName.zip"

    #Get the Linux node VM status (assumption one node with linux type is available)
    [string]$linuxNodeState = GetLinuxNodeStatus

    $k8sSetup = Get-Installedk2sSetupType

    # Host general information and node dump
    Write-Log 'Gathering node details..' -Console
    New-Item -ItemType Directory -Path $hostInfoDir -Force | Out-Null
    DumpNodeDetails $hostInfoDir $linuxNodeState $k8sSetup

    # Log Collection
    Write-Log 'Gathering logs..' -Console
    New-Item -ItemType Directory -Path $tempConfigDir -Force | Out-Null
    Copy-Item -Path $logsDir -Destination $tempLogsDir -Exclude '*.zip' -Force -Recurse

    # Config Collection
    Write-Log 'Gathering config files..' -Console
    Copy-Item -Path $global:JsonConfigFile, $global:SetupJsonFile -Destination $tempConfigDir -Force -ErrorAction SilentlyContinue # Continue if the k2s is not installed and setup.json is not found
    # Network dump
    & $PSScriptRoot\NetworkDump.ps1 -DumpDir $tempNetworkDir -LinuxMasterState $linuxNodeState

    # Final dump of logs and cleanup
    Write-Log "Dumping to $dumpTargetDir.." -Console
    Compress-Archive -Path $tempDir -DestinationPath $dumpTargetPath -CompressionLevel Optimal -Force
    Remove-Item -Path $tempDir -Recurse -Force

    Write-Log "Dump created at $dumpTargetPath" -Console
    Write-Log 'k2s system dump finished'

    if ($OpenDumpFolder -eq $true) {
        Write-Log 'Opening the dump folder..' -Console
        Invoke-Item $dumpTargetDir
    }
    else {
        Write-Log 'Skipping opening the dump folder' -Console
    }

    exit 0
}
catch {
    $exceptionString = $_ | Out-String

    Write-Log "Error occurred: $exceptionString" -Error
    exit -1
}
