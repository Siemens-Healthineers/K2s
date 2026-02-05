# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

# Phase timing & size formatting utilities for delta packaging

# Script-level phase tracking for numbered phase output (Phase X/Y format)
$script:DeltaPhaseNumber = 0
$script:DeltaTotalPhases = 0

<#
.SYNOPSIS
    Initializes the phase tracking system with the total number of phases.
.DESCRIPTION
    Call this once at the start of delta package creation to set up numbered phase logging.
.PARAMETER TotalPhases
    Total number of phases that will be executed.
#>
function Initialize-PhaseTracking {
    param(
        [Parameter(Mandatory)] [int] $TotalPhases
    )
    $script:DeltaPhaseNumber = 0
    $script:DeltaTotalPhases = $TotalPhases
    Write-Log "[DeltaPackage] Starting delta creation with $TotalPhases phases" -Console
}

<#
.SYNOPSIS
    Starts a named phase and returns a stopwatch for timing.
.DESCRIPTION
    Logs the phase start with numbered format (Phase X/Y: Name) if tracking is initialized.
.PARAMETER Name
    Name of the phase being started.
.OUTPUTS
    System.Diagnostics.Stopwatch for timing the phase.
#>
function Start-Phase {
    param(
        [Parameter(Mandatory)] [string] $Name
    )
    $script:DeltaPhaseNumber++
    
    if ($script:DeltaTotalPhases -gt 0) {
        Write-Log ("[Phase {0}/{1}] {2} - start" -f $script:DeltaPhaseNumber, $script:DeltaTotalPhases, $Name) -Console
    } else {
        Write-Log "[Phase] $Name - start" -Console
    }
    return [System.Diagnostics.Stopwatch]::StartNew()
}

<#
.SYNOPSIS
    Stops a named phase and logs its duration.
.PARAMETER Name
    Name of the phase being stopped.
.PARAMETER Stopwatch
    Stopwatch returned from Start-Phase.
#>
function Stop-Phase {
    param(
        [string] $Name,
        $Stopwatch
    )
    if ($Stopwatch) {
        $Stopwatch.Stop()
        if ($script:DeltaTotalPhases -gt 0) {
            Write-Log ("[Phase {0}/{1}] {2} - done in {3:N2}s" -f $script:DeltaPhaseNumber, $script:DeltaTotalPhases, $Name, $Stopwatch.Elapsed.TotalSeconds) -Console
        } else {
            Write-Log ("[Phase] {0} - done in {1:N2}s" -f $Name, $Stopwatch.Elapsed.TotalSeconds) -Console
        }
    }
}

function Format-Size {
    param(
        [uint64] $Bytes
    )
    if ($Bytes -lt 1KB) { return "$Bytes B" }
    $kb = [double]$Bytes / 1KB
    if ($kb -lt 1024) { return ("{0:N2} KB" -f $kb) }
    $mb = $kb / 1024
    if ($mb -lt 1024) { return ("{0:N2} MB" -f $mb) }
    $gb = $mb / 1024
    if ($gb -lt 1024) { return ("{0:N2} GB" -f $gb) }
    $tb = $gb / 1024
    return ("{0:N2} TB" -f $tb)
}
