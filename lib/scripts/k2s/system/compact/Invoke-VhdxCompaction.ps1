# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Compacts the Kubemaster VHDX file to reclaim disk space.

.DESCRIPTION
Compacts the Kubemaster VHDX file by running fstrim inside the VM, stopping the cluster,
optimizing the VHDX with Optimize-VHD, and optionally restarting the cluster.

This resolves the "High Water Mark" issue where VHDX files grow when writing data
but don't shrink when files are deleted.

.PARAMETER NoRestart
Keep the cluster stopped after compaction. The cluster is always stopped during compaction;
this flag only controls whether it is restarted afterwards.

.PARAMETER Yes
Skip confirmation prompts. Useful for automation.

.PARAMETER ShowLogs
Show detailed logs in the console.

.EXAMPLE
Invoke-VhdxCompaction.ps1
# Compact VHDX with automatic restart

.EXAMPLE
Invoke-VhdxCompaction.ps1 -NoRestart
# Compact but keep cluster stopped

.EXAMPLE
Invoke-VhdxCompaction.ps1 -Yes
# Skip confirmation prompts

.NOTES
This operation may take 5-10 minutes depending on VHDX size and disk speed.
#>

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Keep cluster stopped after compaction (stop always happens, this skips the restart)')]
    [switch] $NoRestart = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Skip confirmation prompts')]
    [switch] $Yes = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)

$infraModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"

Import-Module $infraModule, $nodeModule, $clusterModule -WarningAction SilentlyContinue

Initialize-Logging -ShowLogs:$ShowLogs


# Ensure we're in the right place
$installationPath = Get-KubePath
Set-Location $installationPath

Write-Log '=====================================' -Console
Write-Log '   K2s VHDX Compaction              ' -Console
Write-Log '=====================================' -Console

# Check if K2s is installed
$setupConfigRoot = Get-RootConfigk2s
if (-not $setupConfigRoot) {
    Write-Log '[Compact] K2s is not installed. Nothing to compact.' -Console
    exit 1
}

# Check if this is a Linux-only installation (no VHDX)
$WSL = Get-ConfigWslFlag
if ($WSL) {
    Write-Log '[Compact] K2s is running on WSL. VHDX compaction is only available for Hyper-V installations.' -Console
    exit 1
}

# Get VM details
$vmName = Get-ConfigControlPlaneNodeHostname
if (-not $vmName) {
    $vmName = 'kubemaster'
}

Write-Log "[Compact] Target VM: $vmName" -Console

# Check if VM exists
$vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
if (-not $vm) {
    Write-Log "[Compact] VM '$vmName' not found. Is K2s installed?" -Console
    exit 1
}

# --- Edge case: VM in intermediate state (Saved / Paused / Starting / Stopping) ---
$intermediateStates = @('Saved', 'Paused', 'Starting', 'Stopping', 'Saving', 'Pausing', 'Resuming', 'FastSaved', 'FastSaving', 'Reset', 'Unknown')
if ($vm.State -in $intermediateStates) {
    Write-Log "[Compact] VM '$vmName' is in state '$($vm.State)'. Compaction requires the VM to be either Running or Off." -Console
    Write-Log '[Compact] Please wait for the VM to reach a stable state, then retry.' -Console
    exit 1
}

# Get VHDX path — pick the primary OS disk (ControllerLocation 0 on first IDE/SCSI controller, or lowest-numbered disk)
$allDisks = $vm | Get-VMHardDiskDrive | Sort-Object -Property ControllerNumber, ControllerLocation
if (-not $allDisks) {
    Write-Log "[Compact] Could not determine VHDX path for VM '$vmName'" -Console
    exit 1
}

$primaryDisk = $allDisks | Select-Object -First 1
$vhdxPath = $primaryDisk.Path

if (-not $vhdxPath) {
    Write-Log "[Compact] Could not determine VHDX path for VM '$vmName'" -Console
    exit 1
}

if (-not (Test-Path $vhdxPath)) {
    Write-Log "[Compact] VHDX file not found: $vhdxPath" -Console
    exit 1
}

Write-Log "[Compact] VHDX path: $vhdxPath" -Console

if ($allDisks.Count -gt 1) {
    Write-Log "[Compact] Note: VM has $($allDisks.Count) disks. Compacting primary OS disk only: $vhdxPath" -Console
}

# --- Edge case: VM has snapshots — Optimize-VHD -Mode Full cannot compact a VHDX with a checkpoint chain ---
$snapshots = Get-VMSnapshot -VMName $vmName -ErrorAction SilentlyContinue
if ($snapshots) {
    Write-Log "[Compact] VM '$vmName' has $($snapshots.Count) snapshot(s). VHDX compaction cannot proceed while snapshots exist." -Console
    Write-Log '[Compact] Please remove all snapshots (checkpoints) via Hyper-V Manager or: Get-VMSnapshot -VMName ' + "'$vmName'" + ' | Remove-VMSnapshot' -Console
    exit 1
}

# Get initial size
$sizeBeforeGB = [math]::Round((Get-Item $vhdxPath).Length / 1GB, 2)
Write-Log "[Compact] Current VHDX size: $sizeBeforeGB GB" -Console

# --- Edge case: Check host free disk space — Optimize-VHD needs up to 1x VHDX size as temp working space ---
$vhdxDrive = Split-Path -Qualifier $vhdxPath
try {
    $hostDisk = Get-PSDrive -Name ($vhdxDrive.TrimEnd(':')) -ErrorAction Stop
    $freeSpaceGB = [math]::Round($hostDisk.Free / 1GB, 2)
    $requiredGB  = $sizeBeforeGB  # conservative: need at least the file size free

    Write-Log "[Compact] Host free disk space on $vhdxDrive $freeSpaceGB GB (required: ~$requiredGB GB)" -Console

    if ($freeSpaceGB -lt $requiredGB) {
        Write-Log "[Compact] Insufficient host disk space. Need at least $requiredGB GB free on $vhdxDrive, but only $freeSpaceGB GB available." -Console
        Write-Log '[Compact] Free up disk space and retry.' -Console
        exit 1
    }
}
catch {
    Write-Log "[Compact] Warning: Could not determine free disk space on $vhdxDrive. Proceeding anyway." -Console
}

# --- Edge case: VHDX already mounted from a previous interrupted run ---
# Note: a VHDX attached to a running VM also reports Attached=$true via Get-VHD,
# but Dismount-VHD cannot dismount it (it is owned by the VM, not mounted as a host disk).
# We only attempt dismount if Get-VHD confirms it is attached, and swallow the error
# if Dismount-VHD fails because the VHDX is VM-owned rather than host-mounted.
try {
    $vhdInfo = Get-VHD -Path $vhdxPath -ErrorAction Stop
    if ($vhdInfo.Attached) {
        Write-Log "[Compact] VHDX appears attached. Attempting to dismount any stale host mount..." -Console
        try {
            Dismount-VHD -Path $vhdxPath -ErrorAction Stop
            Write-Log '[Compact] Stale host mount removed.' -Console
        }
        catch {
            Write-Log "[Compact] Note: VHDX is attached to the VM (not a stale host mount). Continuing..." -Console
        }
    }
}
catch {
    Write-Log "[Compact] Warning: Could not inspect VHD mount state: $_. Proceeding..." -Console
}

# Track if cluster was originally running
$wasRunning = $vm.State -eq 'Running'

# Step 1: Run fstrim if VM is running
if ($wasRunning) {
    Write-Log '[Step 1/6] Running fstrim inside VM to mark freed blocks...' -Console

    try {
        $ipControlPlane = Get-ConfiguredIPControlPlane

        Write-Log "[Step 1/6] Connecting to $vmName ($ipControlPlane)..." -Console
        Write-Log '[Step 1/6] Running fstrim -v /...' -Console

        $fstrimResult = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'sudo fstrim -v /' -IgnoreErrors

        if ($fstrimResult.Output) {
            $trimmedOutput = $fstrimResult.Output -join "`n"
            Write-Log "fstrim result: $trimmedOutput" -Console
        }

        Write-Log 'fstrim completed successfully' -Console
    }
    catch {
        Write-Log "[Step 1/6] Warning: fstrim failed: $_" -Console
        Write-Log '[Step 1/6] Continuing with compaction...' -Console
    }
}
else {
    Write-Log '[Step 1/6] VM is not running. Skipping fstrim.' -Console
}

# Step 2: Confirm stop if running
if ($wasRunning) {
    Write-Log '[Step 2/6] Cluster is currently running and must be stopped for compaction.' -Console

    if (-not $Yes) {
        $confirmation = Read-Host 'Stop cluster now? (y/n)'
        if ($confirmation -ne 'y') {
            Write-Log 'Compaction cancelled by user.' -Console
            exit 0
        }
    }

    Write-Log 'Stopping cluster...' -Console
    & "$PSScriptRoot\..\..\stop\Stop.ps1" -ShowLogs:$ShowLogs -SkipHeaderDisplay

    # Verify VM reached Off state after Stop.ps1 returned
    $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if ($vm -and $vm.State -ne 'Off') {
        Write-Log "[Compact] Error: VM '$vmName' is still in state '$($vm.State)' after stop. Cannot proceed." -Console
        exit 1
    }

    Write-Log 'Cluster stopped successfully' -Console
}
else {
    Write-Log '[Step 2/6] Cluster is already stopped' -Console
}

# Step 3: Mount VHDX read-only
Write-Log '[Step 3/6] Mounting VHDX (read-only)...' -Console

try {
    Mount-VHD -Path $vhdxPath -ReadOnly -ErrorAction Stop
    Write-Log 'VHDX mounted successfully' -Console
}
catch {
    Write-Log "[Compact] Error: Failed to mount VHDX: $_" -Console

    if ($wasRunning -and -not $NoRestart) {
        Write-Log '[Compact] Attempting to restart cluster...' -Console
        & "$PSScriptRoot\..\..\start\Start.ps1" -ShowLogs:$ShowLogs -SkipHeaderDisplay
    }

    exit 1
}

# Step 4: Optimize VHDX
Write-Log '[Step 4/6] Optimizing VHDX (this may take 5-10 minutes)...' -Console

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

try {
    Optimize-VHD -Path $vhdxPath -Mode Full -ErrorAction Stop
    $stopwatch.Stop()

    $elapsed = $stopwatch.Elapsed
    $duration = if ($elapsed.TotalMinutes -ge 1) {
        "$([math]::Round($elapsed.TotalMinutes, 1)) minutes"
    } else {
        "$([math]::Round($elapsed.TotalSeconds, 1)) seconds"
    }
    Write-Log "Optimization completed in $duration" -Console
}
catch {
    $stopwatch.Stop()
    Write-Log "[Compact] Error: Optimization failed: $_" -Console

    # Ensure VHDX is dismounted before attempting restart
    try {
        Dismount-VHD -Path $vhdxPath -ErrorAction SilentlyContinue
        Write-Log '[Compact] VHDX dismounted after optimization failure.' -Console
    }
    catch {
        Write-Log "[Compact] Warning: Could not dismount VHDX after failure: $_" -Console
    }

    if ($wasRunning -and -not $NoRestart) {
        Write-Log '[Compact] Attempting to restart cluster...' -Console
        & "$PSScriptRoot\..\..\start\Start.ps1" -ShowLogs:$ShowLogs -SkipHeaderDisplay
    }

    exit 1
}

# Step 5: Dismount VHDX
Write-Log '[Step 5/6] Dismounting VHDX...' -Console

try {
    Dismount-VHD -Path $vhdxPath -ErrorAction Stop
    Write-Log 'VHDX dismounted successfully' -Console
}
catch {
    Write-Log "[Compact] Warning: Failed to dismount VHDX: $_" -Console
    Write-Log '[Compact] VHDX may still be mounted. You may need to manually dismount it.' -Console
}

# Calculate savings
$sizeAfterGB = [math]::Round((Get-Item $vhdxPath).Length / 1GB, 2)
$savedGB = [math]::Round($sizeBeforeGB - $sizeAfterGB, 2)
$savedPercent = if ($sizeBeforeGB -gt 0) { [math]::Round(($savedGB / $sizeBeforeGB) * 100, 1) } else { 0 }

Write-Log '=====================================' -Console
Write-Log '   Compaction Results               ' -Console
Write-Log '=====================================' -Console
Write-Log "Before:      $sizeBeforeGB GB" -Console
Write-Log "After:       $sizeAfterGB GB" -Console
Write-Log "Saved:       $savedGB GB ($savedPercent%)" -Console
Write-Log '=====================================' -Console

# Step 6: Restart cluster if needed
if ($wasRunning -and -not $NoRestart) {
    Write-Log '[Step 6/6] Restarting cluster...' -Console

    try {
        & "$PSScriptRoot\..\..\start\Start.ps1" -ShowLogs:$ShowLogs -SkipHeaderDisplay
        Write-Log 'Cluster restarted successfully' -Console
    }
    catch {
        Write-Log "[Compact] Warning: Failed to restart cluster: $_" -Console
        Write-Log "[Compact] Please manually start the cluster with: k2s start" -Console
        exit 1
    }
}
elseif (-not $wasRunning) {
    Write-Log '[Step 6/6] Cluster was not running. Not restarting.' -Console
}
else {
    Write-Log '[Step 6/6] Cluster not restarted (--no-restart specified). To restart: k2s start' -Console
}

Write-Log 'VHDX compaction completed successfully!' -Console

