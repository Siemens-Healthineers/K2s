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
Do not restart the cluster after compaction. Use this for maintenance windows.

.PARAMETER SkipFstrim
Skip running fstrim inside the VM. Only use if you've manually run fstrim already.

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
    [parameter(Mandatory = $false, HelpMessage = 'Do not restart cluster after compaction')]
    [switch] $NoRestart = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Skip running fstrim inside VM')]
    [switch] $SkipFstrim = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Skip confirmation prompts')]
    [switch] $Yes = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)

$infraModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"

Import-Module $infraModule, $nodeModule, $clusterModule

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
    Write-Log 'K2s is not installed. Nothing to compact.' -Console
    exit 1
}

# Check if this is a Linux-only installation (no VHDX)
$WSL = Get-ConfigWslFlag
if ($WSL) {
    Write-Log 'K2s is running on WSL. VHDX compaction is only available for Hyper-V installations.' -Console
    exit 1
}

# Get VM details
$vmName = Get-ConfigControlPlaneNodeHostname
if (-not $vmName) {
    $vmName = 'kubemaster'
}

Write-Log "Target VM: $vmName" -Console

# Check if VM exists
$vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
if (-not $vm) {
    Write-Log "VM '$vmName' not found. Is K2s installed?" -Console
    exit 1
}

# Get VHDX path
$vhdxPath = ($vm | Get-VMHardDiskDrive).Path
if (-not $vhdxPath) {
    Write-Log "Could not determine VHDX path for VM '$vmName'" -Console
    exit 1
}

if (-not (Test-Path $vhdxPath)) {
    Write-Log "VHDX file not found: $vhdxPath" -Console
    exit 1
}

Write-Log "VHDX path: $vhdxPath" -Console

# Get initial size
$sizeBeforeGB = [math]::Round((Get-Item $vhdxPath).Length / 1GB, 2)
Write-Log "Current VHDX size: $sizeBeforeGB GB" -Console

# Track if cluster was originally running
$wasRunning = $vm.State -eq 'Running'

# Step 1: Run fstrim if VM is running
if ($wasRunning -and -not $SkipFstrim) {
    Write-Log '' -Console
    Write-Log '[Step 1/6] Running fstrim inside VM to mark freed blocks...' -Console

    try {
        $ipControlPlane = Get-ConfiguredIPControlPlane

        Write-Log "Connecting to $vmName ($ipControlPlane)..." -Console
        Write-Log 'Running fstrim -v /...' -Console

        $fstrimResult = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'sudo fstrim -v /' -IgnoreErrors

        if ($fstrimResult.Output) {
            $trimmedOutput = $fstrimResult.Output -join "`n"
            Write-Log "fstrim result: $trimmedOutput" -Console
        }

        Write-Log 'fstrim completed successfully' -Console
    }
    catch {
        Write-Log "Warning: fstrim failed: $_" -Console
        Write-Log 'Continuing with compaction...' -Console
    }
}
elseif (-not $wasRunning) {
    Write-Log '[Step 1/6] VM is not running. Skipping fstrim.' -Console
}
else {
    Write-Log '[Step 1/6] Skipping fstrim (--skip-fstrim specified)' -Console
}

# Step 2: Confirm stop if running
if ($wasRunning) {
    Write-Log '' -Console
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

    # Wait for VM to fully stop
    $timeout = 60
    $elapsed = 0
    while ($vm.State -ne 'Off' -and $elapsed -lt $timeout) {
        Start-Sleep -Seconds 2
        $elapsed += 2
        $vm = Get-VM -Name $vmName
    }

    if ($vm.State -ne 'Off') {
        Write-Log 'Error: Failed to stop VM within timeout period.' -Console
        exit 1
    }

    Write-Log 'Cluster stopped successfully' -Console
}
else {
    Write-Log '[Step 2/6] Cluster is already stopped' -Console
}

# Step 3: Mount VHDX read-only
Write-Log '' -Console
Write-Log '[Step 3/6] Mounting VHDX (read-only)...' -Console

try {
    Mount-VHD -Path $vhdxPath -ReadOnly -ErrorAction Stop
    Write-Log 'VHDX mounted successfully' -Console
}
catch {
    Write-Log "Error: Failed to mount VHDX: $_" -Console

    # Try to restart VM if it was running
    if ($wasRunning -and -not $NoRestart) {
        Write-Log 'Attempting to restart cluster...' -Console
        & "$PSScriptRoot\..\..\start\Start.ps1" -ShowLogs:$ShowLogs -SkipHeaderDisplay
    }

    exit 1
}

# Step 4: Optimize VHDX
Write-Log '' -Console
Write-Log '[Step 4/6] Optimizing VHDX (this may take 5-10 minutes)...' -Console

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

try {
    Optimize-VHD -Path $vhdxPath -Mode Full -ErrorAction Stop
    $stopwatch.Stop()

    $minutes = [math]::Round($stopwatch.Elapsed.TotalMinutes, 1)
    Write-Log "Optimization completed in $minutes minutes" -Console
}
catch {
    $stopwatch.Stop()
    Write-Log "Error: Optimization failed: $_" -Console

    # Ensure VHDX is dismounted
    try {
        Dismount-VHD -Path $vhdxPath -ErrorAction SilentlyContinue
    }
    catch {
        # Ignore dismount errors
    }

    # Try to restart VM if it was running
    if ($wasRunning -and -not $NoRestart) {
        Write-Log 'Attempting to restart cluster...' -Console
        & "$PSScriptRoot\..\..\start\Start.ps1" -ShowLogs:$ShowLogs -SkipHeaderDisplay
    }

    exit 1
}

# Step 5: Dismount VHDX
Write-Log '' -Console
Write-Log '[Step 5/6] Dismounting VHDX...' -Console

try {
    Dismount-VHD -Path $vhdxPath -ErrorAction Stop
    Write-Log 'VHDX dismounted successfully' -Console
}
catch {
    Write-Log "Warning: Failed to dismount VHDX: $_" -Console
    Write-Log 'VHDX may still be mounted. You may need to manually dismount it.' -Console
}

# Calculate savings
$sizeAfterGB = [math]::Round((Get-Item $vhdxPath).Length / 1GB, 2)
$savedGB = [math]::Round($sizeBeforeGB - $sizeAfterGB, 2)
$savedPercent = if ($sizeBeforeGB -gt 0) { [math]::Round(($savedGB / $sizeBeforeGB) * 100, 1) } else { 0 }

Write-Log '' -Console
Write-Log '=====================================' -Console
Write-Log '   Compaction Results               ' -Console
Write-Log '=====================================' -Console
Write-Log "Before:      $sizeBeforeGB GB" -Console
Write-Log "After:       $sizeAfterGB GB" -Console
Write-Log "Saved:       $savedGB GB ($savedPercent%)" -Console
Write-Log '=====================================' -Console

# Step 6: Restart cluster if needed
if ($wasRunning -and -not $NoRestart) {
    Write-Log '' -Console
    Write-Log '[Step 6/6] Restarting cluster...' -Console

    try {
        & "$PSScriptRoot\..\..\start\Start.ps1" -ShowLogs:$ShowLogs -SkipHeaderDisplay
        Write-Log 'Cluster restarted successfully' -Console
    }
    catch {
        Write-Log "Warning: Failed to restart cluster: $_" -Console
        Write-Log "Please manually start the cluster with: k2s start" -Console
        exit 1
    }
}
elseif (-not $wasRunning) {
    Write-Log '[Step 6/6] Cluster was not running. Not restarting.' -Console
}
else {
    Write-Log '[Step 6/6] Cluster not restarted (--no-restart specified)' -Console
    Write-Log 'To restart: k2s start' -Console
}

Write-Log '' -Console
Write-Log 'VHDX compaction completed successfully!' -Console

