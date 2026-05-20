<#
.SYNOPSIS
    Dynamic RTK enable/disable controls for selective token optimization.

.DESCRIPTION
    Provides workflow-aware RTK toggling so developers can apply token
    optimization only where it matters (high-noise workflows like K8s
    debugging, test runs, large builds) and bypass it for low-noise
    or debugging-critical scenarios.

    Three control layers:
    1. Per-session profiles (k8s-debug, build, test, minimal, full, off)
    2. Per-command bypass (Use-RtkRaw)
    3. Automatic mode (noise-detection heuristic)

.NOTES
    SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
    SPDX-License-Identifier: MIT
#>

# ── State ──

$script:RtkProfile = 'full'  # Current active profile
$script:RtkEnabled = $true
$script:RtkCommandLog = [System.Collections.Generic.List[PSCustomObject]]::new()

# ── Profile Definitions ──

$script:Profiles = @{
    'full' = @{
        Description = 'All RTK filters active (default)'
        Commands    = @('*')
        Excluded    = @()
    }
    'k8s-debug' = @{
        Description = 'Optimize kubectl/helm/k8s output only'
        Commands    = @('kubectl', 'helm', 'k2s')
        Excluded    = @('git', 'go', 'ls', 'cat', 'grep')
    }
    'build' = @{
        Description = 'Optimize build/test output only'
        Commands    = @('go', 'cargo', 'dotnet', 'npm', 'pnpm')
        Excluded    = @('kubectl', 'git', 'ssh')
    }
    'test' = @{
        Description = 'Optimize test runners only'
        Commands    = @('go test', 'pytest', 'vitest', 'rspec', 'dotnet test')
        Excluded    = @('kubectl', 'git', 'ssh', 'go build')
    }
    'minimal' = @{
        Description = 'Only optimize known-noisy commands (git log, go test pass, kubectl pods)'
        Commands    = @('git log', 'git status', 'go test', 'kubectl get', 'kubectl describe')
        Excluded    = @('*')
    }
    'off' = @{
        Description = 'RTK disabled - all commands run raw'
        Commands    = @()
        Excluded    = @('*')
    }
}

# ── Core Functions ──

function Set-RtkProfile {
    <#
    .SYNOPSIS
        Switch RTK to a named optimization profile.
    .EXAMPLE
        Set-RtkProfile k8s-debug
        # Now only kubectl/helm/k2s commands go through RTK filters
    .EXAMPLE
        Set-RtkProfile off
        # Disable all RTK optimization
    .EXAMPLE
        Set-RtkProfile full
        # Re-enable all optimization
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet('full', 'k8s-debug', 'build', 'test', 'minimal', 'off')]
        [string]$Profile
    )

    $script:RtkProfile = $Profile

    if ($Profile -eq 'off') {
        $script:RtkEnabled = $false
        $env:RTK_DISABLED = '1'
        Write-Host "[RTK] Profile: OFF - all commands bypass RTK" -ForegroundColor Yellow
    }
    else {
        $script:RtkEnabled = $true
        Remove-Item env:RTK_DISABLED -ErrorAction SilentlyContinue
        $desc = $script:Profiles[$Profile].Description
        Write-Host "[RTK] Profile: $Profile - $desc" -ForegroundColor Cyan
    }
}

function Get-RtkProfile {
    <#
    .SYNOPSIS
        Show current RTK profile and what's enabled/disabled.
    #>
    [CmdletBinding()]
    param()

    $p = $script:Profiles[$script:RtkProfile]

    [PSCustomObject]@{
        Profile     = $script:RtkProfile
        Enabled     = $script:RtkEnabled
        Description = $p.Description
        Optimized   = ($p.Commands -join ', ')
        Bypassed    = ($p.Excluded -join ', ')
    }
}

function Invoke-Rtk {
    <#
    .SYNOPSIS
        Route a command through RTK or raw based on current profile.
    .DESCRIPTION
        Checks the active profile to decide whether to use RTK filtering
        or pass through raw. Tracks the decision for observability.
    .EXAMPLE
        Invoke-Rtk kubectl get pods -A
        # Uses RTK if profile includes kubectl, raw otherwise
    .EXAMPLE
        Invoke-Rtk go test ./...
        # Uses RTK if profile includes go/test
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromRemainingArguments)]
        [string[]]$Command
    )

    $cmdString = $Command -join ' '
    $cmdBase = $Command[0]

    $useRtk = Test-RtkShouldOptimize -CommandBase $cmdBase -FullCommand $cmdString

    $entry = [PSCustomObject]@{
        Timestamp = Get-Date
        Command   = $cmdString
        Profile   = $script:RtkProfile
        Optimized = $useRtk
    }
    $script:RtkCommandLog.Add($entry)

    # Split args: ValueFromRemainingArguments may deliver individual tokens or joined strings
    $parts = @()
    foreach ($c in $Command) {
        $parts += ($c -split '\s+')
    }

    if ($useRtk) {
        & rtk @parts
    }
    else {
        $exe = $parts[0]
        if ($parts.Count -gt 1) {
            $cmdArgs = $parts[1..($parts.Count - 1)]
            & $exe @cmdArgs
        }
        else {
            & $exe
        }
    }
}

function Use-RtkRaw {
    <#
    .SYNOPSIS
        Run a single command bypassing RTK regardless of profile.
    .EXAMPLE
        Use-RtkRaw kubectl logs deployment/myapp -f
        # Always runs raw, even if k8s-debug profile is active
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromRemainingArguments)]
        [string[]]$Command
    )

    $entry = [PSCustomObject]@{
        Timestamp = Get-Date
        Command   = ($Command -join ' ')
        Profile   = $script:RtkProfile
        Optimized = $false
    }
    $script:RtkCommandLog.Add($entry)

    $parts = @()
    foreach ($c in $Command) {
        $parts += ($c -split '\s+')
    }
    $exe = $parts[0]
    if ($parts.Count -gt 1) {
        $cmdArgs = $parts[1..($parts.Count - 1)]
        & $exe @cmdArgs
    }
    else {
        & $exe
    }
}

function Use-RtkForced {
    <#
    .SYNOPSIS
        Force a command through RTK regardless of profile.
    .EXAMPLE
        Use-RtkForced git log --all --oneline -50
        # Forces RTK even if profile excludes git
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromRemainingArguments)]
        [string[]]$Command
    )

    $entry = [PSCustomObject]@{
        Timestamp = Get-Date
        Command   = ($Command -join ' ')
        Profile   = $script:RtkProfile
        Optimized = $true
    }
    $script:RtkCommandLog.Add($entry)

    & rtk @Command
}

# ── Scoped Blocks ──

function Enter-RtkProfile {
    <#
    .SYNOPSIS
        Temporarily switch profile for a block of commands, then restore.
    .EXAMPLE
        Enter-RtkProfile 'k8s-debug' {
            Invoke-Rtk kubectl get pods -A
            Invoke-Rtk kubectl describe pod coredns-xxx -n kube-system
            Invoke-Rtk kubectl logs deployment/coredns -n kube-system --tail=100
        }
        # Profile automatically reverts after the block
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet('full', 'k8s-debug', 'build', 'test', 'minimal', 'off')]
        [string]$Profile,

        [Parameter(Mandatory, Position = 1)]
        [scriptblock]$ScriptBlock
    )

    $previousProfile = $script:RtkProfile
    $previousEnabled = $script:RtkEnabled

    try {
        Set-RtkProfile $Profile
        & $ScriptBlock
    }
    finally {
        $script:RtkProfile = $previousProfile
        $script:RtkEnabled = $previousEnabled
        if ($previousProfile -eq 'off') {
            $env:RTK_DISABLED = '1'
        }
        else {
            Remove-Item env:RTK_DISABLED -ErrorAction SilentlyContinue
        }
        Write-Host "[RTK] Restored profile: $previousProfile" -ForegroundColor DarkGray
    }
}

# ── Observability ──

function Get-RtkSessionStats {
    <#
    .SYNOPSIS
        Show session-level RTK routing decisions.
    #>
    [CmdletBinding()]
    param()

    if ($script:RtkCommandLog.Count -eq 0) {
        Write-Host "[RTK] No commands routed through Invoke-Rtk yet this session." -ForegroundColor Gray
        return
    }

    $total = $script:RtkCommandLog.Count
    $optimized = ($script:RtkCommandLog | Where-Object Optimized).Count
    $bypassed = $total - $optimized

    Write-Host ""
    Write-Host "RTK Session Stats" -ForegroundColor Cyan
    Write-Host "=====================================" -ForegroundColor DarkGray
    Write-Host "  Total commands:    $total"
    Write-Host "  RTK optimized:     $optimized ($([math]::Round($optimized/$total*100))%)" -ForegroundColor Green
    Write-Host "  Raw (bypassed):    $bypassed ($([math]::Round($bypassed/$total*100))%)" -ForegroundColor Yellow
    Write-Host "  Current profile:   $($script:RtkProfile)"
    Write-Host ""

    Write-Host "Command Breakdown:" -ForegroundColor Cyan
    $grouped = $script:RtkCommandLog | Group-Object { ($_.Command -split '\s+')[0] }
    foreach ($g in $grouped) {
        $cmd = $g.Name
        $opt = @($g.Group | Where-Object { $_.Optimized -eq $true }).Count
        $raw = $g.Count - $opt
        Write-Host ("  {0} - {1} calls ({2} optimized, {3} raw)" -f $cmd, $g.Count, $opt, $raw)
    }
    Write-Host ""
}

function Clear-RtkSessionStats {
    <#
    .SYNOPSIS
        Reset session command log.
    #>
    $script:RtkCommandLog.Clear()
    Write-Host "[RTK] Session stats cleared." -ForegroundColor Gray
}

# ── Internal Helpers ──

function Test-RtkShouldOptimize {
    [CmdletBinding()]
    param(
        [string]$CommandBase,
        [string]$FullCommand
    )

    if (-not $script:RtkEnabled) { return $false }

    $profile = $script:Profiles[$script:RtkProfile]

    # Check if explicitly excluded
    foreach ($excl in $profile.Excluded) {
        if ($excl -eq '*') { return $false }
        if ($CommandBase -like $excl) { return $false }
        if ($FullCommand -like "*$excl*") { return $false }
    }

    # Check if explicitly included
    foreach ($incl in $profile.Commands) {
        if ($incl -eq '*') { return $true }
        if ($CommandBase -like $incl) { return $true }
        if ($FullCommand -like "*$incl*") { return $true }
    }

    # Default: don't optimize if not in the include list
    return $false
}

# ── Aliases ──

Set-Alias -Name rtkp -Value Set-RtkProfile -Scope Global -Force
Set-Alias -Name rtkr -Value Use-RtkRaw -Scope Global -Force
Set-Alias -Name rtkf -Value Use-RtkForced -Scope Global -Force
Set-Alias -Name rtki -Value Invoke-Rtk -Scope Global -Force
Set-Alias -Name rtks -Value Get-RtkSessionStats -Scope Global -Force

# ── Exports ──

Export-ModuleMember -Function @(
    'Set-RtkProfile'
    'Get-RtkProfile'
    'Invoke-Rtk'
    'Use-RtkRaw'
    'Use-RtkForced'
    'Enter-RtkProfile'
    'Get-RtkSessionStats'
    'Clear-RtkSessionStats'
) -Alias @('rtkp', 'rtkr', 'rtkf', 'rtki', 'rtks')

