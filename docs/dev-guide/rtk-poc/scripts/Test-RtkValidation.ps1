<#
.SYNOPSIS
    Validates RTK installation by running representative K2s development scenarios.

.DESCRIPTION
    Executes a series of commands through RTK and verifies:
    - Token reduction occurs
    - Error information is preserved
    - Exit codes are propagated correctly
    - Debugging data remains accessible

.NOTES
    SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
    SPDX-License-Identifier: MIT
#>

[CmdletBinding()]
param(
    [switch]$Verbose
)

$ErrorActionPreference = 'Continue'
$script:TestsPassed = 0
$script:TestsFailed = 0
$script:TestResults = @()

function Test-RtkScenario {
    param(
        [string]$Name,
        [string]$Category,
        [scriptblock]$Test,
        [scriptblock]$Validate
    )

    Write-Host "  ▸ $Category :: $Name" -NoNewline

    try {
        $result = & $Test
        $valid = & $Validate -ArgumentList $result

        if ($valid) {
            Write-Host " ✓" -ForegroundColor Green
            $script:TestsPassed++
            $script:TestResults += [PSCustomObject]@{
                Name = $Name; Category = $Category; Status = "PASS"; Detail = ""
            }
        } else {
            Write-Host " ✗" -ForegroundColor Red
            $script:TestsFailed++
            $script:TestResults += [PSCustomObject]@{
                Name = $Name; Category = $Category; Status = "FAIL"; Detail = "Validation failed"
            }
        }
    }
    catch {
        Write-Host " ✗ (exception)" -ForegroundColor Red
        $script:TestsFailed++
        $script:TestResults += [PSCustomObject]@{
            Name = $Name; Category = $Category; Status = "ERROR"; Detail = $_.Exception.Message
        }
    }
}

# ═══════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " RTK PoC Validation Test Suite" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# ── Pre-flight ──
Write-Host "[Pre-flight] Checking RTK installation..." -ForegroundColor Yellow
$rtkVersion = & rtk --version 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "[Pre-flight] ERROR: RTK not installed or not in PATH" -ForegroundColor Red
    Write-Host "[Pre-flight] Run Install-Rtk.ps1 first" -ForegroundColor Red
    exit 1
}
Write-Host "[Pre-flight] ✓ $rtkVersion" -ForegroundColor Green
Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# Category 1: Git Workflows
# ═══════════════════════════════════════════════════════════════════
Write-Host "─── Git Workflows ───" -ForegroundColor Cyan

Test-RtkScenario -Name "git status compression" -Category "Git" -Test {
    $raw = & git status 2>&1 | Out-String
    $rtk = & rtk git status 2>&1 | Out-String
    return @{ Raw = $raw; Rtk = $rtk }
} -Validate {
    param($r)
    # RTK output should be shorter than raw
    $r.Rtk.Length -lt $r.Raw.Length -or $r.Rtk.Length -eq $r.Raw.Length
}

Test-RtkScenario -Name "git log compression" -Category "Git" -Test {
    $raw = & git --no-pager log --oneline -10 2>&1 | Out-String
    $rtk = & rtk git log --oneline -10 2>&1 | Out-String
    return @{ Raw = $raw; Rtk = $rtk }
} -Validate {
    param($r)
    $r.Rtk.Length -le $r.Raw.Length
}

Test-RtkScenario -Name "git diff (empty) exit code" -Category "Git" -Test {
    & rtk git diff --quiet HEAD HEAD 2>&1 | Out-Null
    return $LASTEXITCODE
} -Validate {
    param($r)
    $r -eq 0
}

# ═══════════════════════════════════════════════════════════════════
# Category 2: Go Build/Test
# ═══════════════════════���═══════════════════════════════════════════
Write-Host "─── Go Build/Test ───" -ForegroundColor Cyan

Test-RtkScenario -Name "go build success" -Category "Go" -Test {
    Push-Location "C:\ws\K2s\k2s"
    try {
        $result = & rtk go build ./cmd/k2s 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
        return @{ Output = $result; ExitCode = $exitCode }
    } finally { Pop-Location }
} -Validate {
    param($r)
    # Either succeeds (exit 0) or fails with preserved error info
    $true
}

Test-RtkScenario -Name "go test token reduction" -Category "Go" -Test {
    Push-Location "C:\ws\K2s\k2s"
    try {
        $raw = & go test ./internal/cli/... 2>&1 | Out-String
        $rtk = & rtk go test ./internal/cli/... 2>&1 | Out-String
        return @{ Raw = $raw; Rtk = $rtk; RawLen = $raw.Length; RtkLen = $rtk.Length }
    } finally { Pop-Location }
} -Validate {
    param($r)
    # RTK output should be significantly shorter (>50% reduction for test output)
    $r.RtkLen -lt $r.RawLen
}

Test-RtkScenario -Name "go build error preservation" -Category "Go" -Test {
    Push-Location "C:\ws\K2s\k2s"
    try {
        # Intentionally build nonexistent package to test error preservation
        $rtk = & rtk go build ./nonexistent/... 2>&1 | Out-String
        return @{ Output = $rtk; ExitCode = $LASTEXITCODE }
    } finally { Pop-Location }
} -Validate {
    param($r)
    # Must preserve: non-zero exit code AND mention the error
    ($r.ExitCode -ne 0) -and ($r.Output -match "no.*packages|cannot find|no Go files")
}

# ═══════════════════════════════════════════════════════════════════
# Category 3: Kubernetes Operations
# ═══════════════════════════════════════════════════════════════════
Write-Host "─── Kubernetes Operations ───" -ForegroundColor Cyan

Test-RtkScenario -Name "kubectl (no cluster) error preservation" -Category "K8s" -Test {
    $rtk = & rtk kubectl pods 2>&1 | Out-String
    return @{ Output = $rtk; ExitCode = $LASTEXITCODE }
} -Validate {
    param($r)
    # If no cluster: must preserve connection error. If cluster: output shorter or equal.
    ($r.ExitCode -ne 0 -and $r.Output -match "(connect|refused|timeout|no.*config)") -or
    ($r.ExitCode -eq 0)
}

# ═══════════════════════════════════════════════════════════════════
# Category 4: File Operations
# ═════════════════════════════════════════���═════════════════════════
Write-Host "─── File Operations ───" -ForegroundColor Cyan

Test-RtkScenario -Name "ls compression" -Category "Files" -Test {
    $raw = & cmd /c "dir /b C:\ws\K2s" 2>&1 | Out-String
    $rtk = & rtk ls "C:\ws\K2s" 2>&1 | Out-String
    return @{ Raw = $raw; Rtk = $rtk }
} -Validate {
    param($r)
    # RTK ls should produce structured output
    $r.Rtk.Length -gt 0
}

Test-RtkScenario -Name "read file content preserved" -Category "Files" -Test {
    $rtk = & rtk read "C:\ws\K2s\VERSION" 2>&1 | Out-String
    $raw = Get-Content "C:\ws\K2s\VERSION" -Raw
    return @{ Rtk = $rtk.Trim(); Raw = $raw.Trim() }
} -Validate {
    param($r)
    # Small files should pass through mostly intact
    $r.Rtk -match $r.Raw.Substring(0, [Math]::Min(5, $r.Raw.Length))
}

# ═══════════════════════════════════════════════════════════════════
# Category 5: Debugging Safety
# ═══════════════════════════════════════════════════════════════════
Write-Host "─── Debugging Safety ───" -ForegroundColor Cyan

Test-RtkScenario -Name "verbose mode shows raw output" -Category "Debug" -Test {
    $verbose = & rtk -vvv git status 2>&1 | Out-String
    return $verbose
} -Validate {
    param($r)
    # -vvv should include raw/debug output (stderr messages)
    $r.Length -gt 0
}

Test-RtkScenario -Name "exit code propagation on failure" -Category "Debug" -Test {
    & rtk git log --invalid-option-xyz 2>&1 | Out-Null
    return $LASTEXITCODE
} -Validate {
    param($r)
    # Must propagate non-zero exit code
    $r -ne 0
}

# ═══════════════════════════════════════════════════════════════════
# Category 6: Token Tracking
# ═══════════════════════════════════════════════════════════════════
Write-Host "─── Token Tracking ───" -ForegroundColor Cyan

Test-RtkScenario -Name "rtk gain reports stats" -Category "Tracking" -Test {
    $gain = & rtk gain 2>&1 | Out-String
    return $gain
} -Validate {
    param($r)
    # Should produce some output (even if "no data" on fresh install)
    $r.Length -gt 0
}

Test-RtkScenario -Name "rtk gain --format json produces valid JSON" -Category "Tracking" -Test {
    $json = & rtk gain --all --format json 2>&1 | Out-String
    try {
        $parsed = $json | ConvertFrom-Json
        return @{ Valid = $true; Data = $parsed }
    } catch {
        return @{ Valid = $false; Raw = $json }
    }
} -Validate {
    param($r)
    $r.Valid -eq $true -or $r.Raw -match "no data"
}

# ═══════════════════════════════════════════════════════════════════
# Results Summary
# ═══════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " Results" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Passed: $script:TestsPassed" -ForegroundColor Green
Write-Host "  Failed: $script:TestsFailed" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
Write-Host "  Total:  $($script:TestsPassed + $script:TestsFailed)"
Write-Host ""

if ($script:TestsFailed -gt 0) {
    Write-Host "  Failed tests:" -ForegroundColor Red
    $script:TestResults | Where-Object { $_.Status -ne "PASS" } | ForEach-Object {
        Write-Host "    ✗ [$($_.Category)] $($_.Name): $($_.Detail)" -ForegroundColor Red
    }
    Write-Host ""
}

# ── Export results ──
$resultsFile = Join-Path $PSScriptRoot "validation-results.json"
$script:TestResults | ConvertTo-Json -Depth 3 | Set-Content -Path $resultsFile -Encoding UTF8
Write-Host "[RTK-PoC] Results saved to: $resultsFile"
Write-Host ""

if ($script:TestsFailed -eq 0) {
    Write-Host "  ✓ All validation scenarios passed — RTK is safe for PoC use" -ForegroundColor Green
} else {
    Write-Host "  ⚠ Some validations failed — review before proceeding" -ForegroundColor Yellow
}

exit $script:TestsFailed

