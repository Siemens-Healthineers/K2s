# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Mounts a CephFS filesystem on a Windows node via ceph-dokan and registers a startup task.

.DESCRIPTION
Runs ON a Windows node after Install-CephForWindows.ps1 has installed the native Ceph client
(ceph-dokan.exe + Dokany) and written C:\ProgramData\ceph\ceph.conf and the client keyring. This
script mounts the CephFS filesystem to a local directory mount point using ceph-dokan and registers a
scheduled task so the mount is re-established automatically after a reboot. The mounted directory can
then be consumed by Windows pods through a hostPath volume (there is no upstream Windows CephFS CSI
node plugin, so hostPath is the supported consumption path for the native client).

With -Unmount the script tears the mount down again: it stops and removes the scheduled task and
terminates the ceph-dokan process.

This script is dispatched by scripts/windows/New-CephWindowsNode.ps1 (locally for a HOST Windows
worker node, or remotely for a VM-EXISTING Windows node).

See https://docs.ceph.com/en/latest/man/8/ceph-dokan/ for the ceph-dokan options.

.PARAMETER CephFsName
Name of the CephFS filesystem to mount (e.g. 'cephfs'). When set it is passed to ceph-dokan as
--client_fs so the correct filesystem is selected on multi-filesystem clusters.

.PARAMETER CephUser
The CephX user name (defaults to 'client.admin'). The 'client.' prefix is optional; it is stripped
before being passed to ceph-dokan --id.

.PARAMETER MountPoint
The local directory mount point where CephFS is mounted (default 'C:\ceph\data'). It must be an empty
directory; it is created if it does not exist. A single drive letter (e.g. 'X:') is also accepted.

.PARAMETER Unmount
If set, removes the mount (stops/unregisters the scheduled task and terminates ceph-dokan) instead of
creating it.

.PARAMETER ShowLogs
If log output shall be streamed also to CLI output.
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'CephFS filesystem name (--client_fs)')]
    [string] $CephFsName = '',
    [parameter(Mandatory = $false, HelpMessage = 'CephX user name')]
    [string] $CephUser = 'client.admin',
    [parameter(Mandatory = $false, HelpMessage = 'Local directory mount point for CephFS')]
    [string] $MountPoint = 'C:\ceph\data',
    [parameter(Mandatory = $false, HelpMessage = 'Remove the CephFS mount instead of creating it')]
    [switch] $Unmount = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)

$infraModule = "$PSScriptRoot/../../../../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
if (Test-Path -Path $infraModule) {
    Import-Module $infraModule
    Initialize-Logging -ShowLogs:$ShowLogs
}
else {
    # When this script is executed on a remote Windows worker node it is copied outside of the K2s
    # module tree, so the infra module is not available. Provide minimal logging fallbacks so the
    # mount remains fully self-contained.
    if (-not (Get-Command -Name 'Write-Log' -ErrorAction SilentlyContinue)) {
        function Write-Log { param([Parameter(ValueFromPipeline = $true)][string]$Message, [switch]$Console) process { Write-Output $Message } }
    }
    if (-not (Get-Command -Name 'Initialize-Logging' -ErrorAction SilentlyContinue)) {
        function Initialize-Logging { param([switch]$ShowLogs) }
    }
}

$cephConfPath = "$env:ProgramData\ceph\ceph.conf"
$scheduledTaskName = 'K2s-CephFS-Mount'

function Update-PathFromRegistry {
    # After an MSI install the machine PATH is written to the registry but the current PowerShell
    # process does not pick it up automatically. Merge it so Get-Command finds new binaries.
    $machinePath = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
    $userPath = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
    $env:PATH = (@($machinePath, $userPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ';'
}

function Resolve-CephDokanPath {
    # ceph-dokan.exe is shipped by the Ceph for Windows MSI. Prefer PATH, then the default location.
    # Refresh PATH first in case the MSI just ran in this session.
    Update-PathFromRegistry
    $cmd = Get-Command 'ceph-dokan.exe' -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { return $cmd.Source }

    foreach ($candidate in @("$env:ProgramFiles\Ceph\bin\ceph-dokan.exe", "$env:ProgramFiles\Ceph\ceph-dokan.exe")) {
        if (Test-Path -Path $candidate) { return $candidate }
    }
    return ''
}

function Get-CephClientId {
    param([string]$User)
    $id = "$User".Trim()
    if ([string]::IsNullOrWhiteSpace($id)) { return 'admin' }
    if ($id.StartsWith('client.')) { $id = $id.Substring('client.'.Length) }
    return $id
}

function Remove-CephFsMount {
    Write-Log "[CephWin] Removing CephFS mount and scheduled task '$scheduledTaskName'" -Console

    $existingTask = Get-ScheduledTask -TaskName $scheduledTaskName -ErrorAction SilentlyContinue
    if ($null -ne $existingTask) {
        try { Stop-ScheduledTask -TaskName $scheduledTaskName -ErrorAction SilentlyContinue } catch { }
        Unregister-ScheduledTask -TaskName $scheduledTaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Log "[CephWin] Scheduled task '$scheduledTaskName' removed." -Console
    }
    else {
        Write-Log "[CephWin] Scheduled task '$scheduledTaskName' not present; nothing to unregister." -Console
    }

    # Terminate any running ceph-dokan process so the Dokany mount is released.
    $dokanProcesses = Get-Process -Name 'ceph-dokan' -ErrorAction SilentlyContinue
    foreach ($proc in $dokanProcesses) {
        try {
            Stop-Process -Id $proc.Id -Force -ErrorAction Stop
            Write-Log "[CephWin] Stopped ceph-dokan process (PID $($proc.Id))." -Console
        }
        catch {
            Write-Log "[CephWin] WARNING: Could not stop ceph-dokan process (PID $($proc.Id)): $($_.Exception.Message)" -Console
        }
    }
}

function New-CephFsMount {
    $cephDokan = Resolve-CephDokanPath
    if ([string]::IsNullOrWhiteSpace($cephDokan)) {
        throw 'ceph-dokan.exe not found. Ensure the Ceph for Windows client is installed (Install-CephForWindows.ps1) before mounting CephFS.'
    }
    if (-not (Test-Path -Path $cephConfPath)) {
        throw "Ceph client configuration not found at '$cephConfPath'. Run Install-CephForWindows.ps1 first."
    }

    $clientId = Get-CephClientId -User $CephUser

    # A directory mount point must exist and be empty; a drive letter (e.g. 'X:') is passed as-is.
    $isDriveLetter = ($MountPoint -match '^[A-Za-z]:?$')
    if (-not $isDriveLetter) {
        if (-not (Test-Path -Path $MountPoint)) {
            New-Item -Path $MountPoint -ItemType Directory -Force | Out-Null
        }
    }

    # Build the ceph-dokan argument line. Paths are quoted for the scheduled-task action string.
    $argument = "map -c `"$cephConfPath`" --id $clientId -l `"$MountPoint`""
    if (-not [string]::IsNullOrWhiteSpace($CephFsName)) {
        $argument += " --client_fs $CephFsName"
    }

    Write-Log "[CephWin] Registering startup task '$scheduledTaskName' to mount CephFS at '$MountPoint'" -Console
    Write-Log "[CephWin] ceph-dokan command: `"$cephDokan`" $argument"

    # Re-create the task so re-enabling is idempotent and picks up any changed parameters.
    if ($null -ne (Get-ScheduledTask -TaskName $scheduledTaskName -ErrorAction SilentlyContinue)) {
        Unregister-ScheduledTask -TaskName $scheduledTaskName -Confirm:$false -ErrorAction SilentlyContinue
    }

    $action = New-ScheduledTaskAction -Execute $cephDokan -Argument $argument
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    # ceph-dokan is a long-running foreground daemon: no execution time limit, restart if it exits.
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

    Register-ScheduledTask -TaskName $scheduledTaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null

    # Mount now (without waiting for a reboot) by starting the task.
    Start-ScheduledTask -TaskName $scheduledTaskName

    # Give ceph-dokan a few seconds to establish the Dokany mount, then verify best-effort.
    $mounted = $false
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 2
        $dokanRunning = $null -ne (Get-Process -Name 'ceph-dokan' -ErrorAction SilentlyContinue)
        $mountReachable = if ($isDriveLetter) { Test-Path -Path (($MountPoint.TrimEnd(':')) + ':\') } else { Test-Path -Path $MountPoint }
        if ($dokanRunning -and $mountReachable) { $mounted = $true; break }
    }

    if ($mounted) {
        Write-Log "[CephWin] CephFS mounted at '$MountPoint'. Windows pods can consume it via a hostPath volume." -Console
    }
    else {
        Write-Log "[CephWin] WARNING: Could not confirm the CephFS mount at '$MountPoint' within the timeout. The startup task '$scheduledTaskName' is registered; check 'Get-ScheduledTask -TaskName $scheduledTaskName' and the ceph-dokan log under C:\ProgramData\ceph\out." -Console
    }
}

try {
    if ($Unmount) {
        Remove-CephFsMount
    }
    else {
        New-CephFsMount
    }
    exit 0
}
catch {
    Write-Log "[CephWin] ERROR: $($_.Exception.Message)" -Console
    exit 1
}
