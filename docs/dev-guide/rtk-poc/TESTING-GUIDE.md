<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# RTK PoC — Execution & Testing Guide

> **Purpose**: Step-by-step guide for executing and validating the RTK PoC.  
> **Prerequisites**: PoC implementation package is complete (scripts, filters, observability).  
> **Time Required**: ~2-3 hours for full validation; can be done incrementally.

---

## How to Use This Document

Execute each section sequentially. For each step:
1. Run the command
2. Record the output in the **Observations** column
3. Mark **PASS** or **FAIL** based on criteria
4. If FAIL: check Troubleshooting section, then decide whether to continue or stop

```
Legend:
  ✅ = PASS
  ❌ = FAIL (blocking — investigate before continuing)
  ⚠️ = WARN (non-blocking — note and continue)
  ⏭️ = SKIP (not applicable to current environment)
```

---

## 1. Pre-Validation Checklist

### 1.1 Environment Verification

| # | Check | Command | Expected | Result |
|---|-------|---------|----------|--------|
| 1.1.1 | PowerShell version | `$PSVersionTable.PSVersion` | 5.1+ or 7.x | |
| 1.1.2 | Go installed | `go version` | go1.21+ | |
| 1.1.3 | Git installed | `git --version` | 2.x | |
| 1.1.4 | K2s repo accessible | `Test-Path C:\ws\K2s\k2s\go.mod` | True | |
| 1.1.5 | kubectl available | `Get-Command kubectl -ErrorAction SilentlyContinue` | Path shown (or skip K8s tests) | |
| 1.1.6 | Internet access (for install) | `Test-NetConnection github.com -Port 443` | TcpTestSucceeded: True | |

### 1.2 Installation Verification

Run the install script:
```powershell
cd C:\ws\K2s\docs\dev-guide\rtk-poc\scripts
.\Install-Rtk.ps1
```

| # | Check | Command | Expected | Result |
|---|-------|---------|----------|--------|
| 1.2.1 | RTK binary exists | `Get-Command rtk` | Path to rtk.exe | |
| 1.2.2 | Version correct | `rtk --version` | `rtk 0.34.3` (or newer) | |
| 1.2.3 | Gain command works | `rtk gain` | Shows stats or "no data" message | |
| 1.2.4 | Config created | `Test-Path "$env:APPDATA\rtk\config.toml"` | True | |
| 1.2.5 | TOML filters present | `Test-Path "C:\ws\K2s\.rtk\filters.toml"` | True | |
| 1.2.6 | Help works | `rtk --help` | Shows command list | |

### 1.3 Shell/PATH Validation

```powershell
# Verify rtk is in PATH
$env:PATH -split ';' | Where-Object { $_ -like '*local*bin*' -or $_ -like '*rtk*' }
```

| # | Check | Command | Expected | Result |
|---|-------|---------|----------|--------|
| 1.3.1 | rtk resolves from any directory | `Push-Location $env:TEMP; rtk --version; Pop-Location` | Version shown | |
| 1.3.2 | No name collision | `rtk gain` | Token stats (not "unknown command") | |

### 1.4 Rollback Readiness

| # | Check | Command | Expected | Result |
|---|-------|---------|----------|--------|
| 1.4.1 | Uninstall script exists | `Test-Path "C:\ws\K2s\docs\dev-guide\rtk-poc\scripts\Uninstall-Rtk.ps1"` | True | |
| 1.4.2 | Direct commands still work | `git --version` | Works without rtk prefix | |
| 1.4.3 | RTK_DISABLED works | `$env:RTK_DISABLED="1"; rtk git status; Remove-Item env:RTK_DISABLED` | Passes through unfiltered | |

### 1.5 Observability Readiness

| # | Check | Command | Expected | Result |
|---|-------|---------|----------|--------|
| 1.5.1 | Metrics script exists | `Test-Path "C:\ws\K2s\docs\dev-guide\rtk-poc\scripts\Start-RtkMetricsExporter.ps1"` | True | |
| 1.5.2 | Grafana dashboard exists | `Test-Path "C:\ws\K2s\docs\dev-guide\rtk-poc\grafana\rtk-dashboard.json"` | True | |
| 1.5.3 | Prometheus config exists | `Test-Path "C:\ws\K2s\docs\dev-guide\rtk-poc\prometheus\rtk-metrics.yml"` | True | |

**Pre-Validation Gate**: All 1.x.x items must be ✅ or ⏭️ before proceeding.

---

## 2. Baseline Capture (WITHOUT RTK)

> **Purpose**: Establish what "normal" output looks like so we can measure RTK's actual impact.

### 2.1 Git Command Baselines

Run these commands **without** `rtk` prefix and record output size:

```powershell
# 2.1.1 — Git status
$gitStatus = (git status 2>&1 | Out-String)
Write-Host "git status: $($gitStatus.Length) chars (~$([math]::Ceiling($gitStatus.Length/4)) tokens)"
```

```powershell
# 2.1.2 — Git log
$gitLog = (git --no-pager log --oneline -20 2>&1 | Out-String)
Write-Host "git log -20: $($gitLog.Length) chars (~$([math]::Ceiling($gitLog.Length/4)) tokens)"
```

```powershell
# 2.1.3 — Git diff (if working changes exist)
$gitDiff = (git --no-pager diff 2>&1 | Out-String)
Write-Host "git diff: $($gitDiff.Length) chars (~$([math]::Ceiling($gitDiff.Length/4)) tokens)"
```

| Baseline | Output Size (chars) | Estimated Tokens | Notes |
|----------|-------------------|------------------|-------|
| `git status` | | | |
| `git log -20` | | | |
| `git diff` | | | |

### 2.2 Go Build/Test Baselines

```powershell
# 2.2.1 — Go build (success)
Push-Location C:\ws\K2s\k2s
$goBuild = (go build ./cmd/k2s 2>&1 | Out-String)
Write-Host "go build (success): $($goBuild.Length) chars (~$([math]::Ceiling($goBuild.Length/4)) tokens)"
```

```powershell
# 2.2.2 — Go test (pick a package with tests)
$goTest = (go test ./internal/cli/... 2>&1 | Out-String)
Write-Host "go test: $($goTest.Length) chars (~$([math]::Ceiling($goTest.Length/4)) tokens)"
```

```powershell
# 2.2.3 — Go build failure
$goBuildFail = (go build ./nonexistent/... 2>&1 | Out-String)
Write-Host "go build (fail): $($goBuildFail.Length) chars (~$([math]::Ceiling($goBuildFail.Length/4)) tokens)"
Pop-Location
```

| Baseline | Output Size (chars) | Estimated Tokens | Notes |
|----------|-------------------|------------------|-------|
| `go build` (success) | | | |
| `go test` (package) | | | |
| `go build` (failure) | | | |

### 2.3 Kubectl Baselines (if cluster available)

```powershell
# 2.3.1 — kubectl get pods
$kubePods = (kubectl get pods -A 2>&1 | Out-String)
Write-Host "kubectl pods: $($kubePods.Length) chars (~$([math]::Ceiling($kubePods.Length/4)) tokens)"
```

```powershell
# 2.3.2 — kubectl describe
$kubeDescribe = (kubectl describe pod -l component=etcd -n kube-system 2>&1 | Out-String)
Write-Host "kubectl describe: $($kubeDescribe.Length) chars (~$([math]::Ceiling($kubeDescribe.Length/4)) tokens)"
```

| Baseline | Output Size (chars) | Estimated Tokens | Notes |
|----------|-------------------|------------------|-------|
| `kubectl get pods -A` | | | |
| `kubectl describe pod` | | | |

### 2.4 File/Directory Baselines

```powershell
# 2.4.1 — Directory listing
$lsOutput = (Get-ChildItem C:\ws\K2s -Recurse -Depth 2 | Format-Table Name, Length | Out-String)
Write-Host "dir listing: $($lsOutput.Length) chars (~$([math]::Ceiling($lsOutput.Length/4)) tokens)"
```

### 2.5 Baseline Summary Table

| Category | Avg Tokens (Raw) | Notes |
|----------|------------------|-------|
| Git commands | | |
| Go build/test | | |
| kubectl | | |
| File operations | | |
| **Total (typical session)** | | |

---

## 3. RTK Validation Scenarios (WITH RTK)

### 3.1 Git Commands

#### 3.1.1 — Git Status (Clean Repo)

```powershell
rtk git status
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| Output is shorter than baseline | Yes — compact summary | | |
| Shows branch name | Yes | | |
| Shows clean/dirty state | Yes | | |
| Exit code | 0 | `$LASTEXITCODE` = | |

#### 3.1.2 — Git Status (Dirty Repo)

```powershell
# Create a temp change
"test" | Out-File -FilePath C:\ws\K2s\tmp\rtk-test-file.txt
rtk git status
Remove-Item C:\ws\K2s\tmp\rtk-test-file.txt -ErrorAction SilentlyContinue
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| Modified/untracked files listed | Yes — file visible | | |
| File path is readable | Yes | | |
| Reduction vs baseline | >50% shorter | | |

#### 3.1.3 — Git Log

```powershell
rtk git log -10
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| Commit hashes present | Yes (short form) | | |
| Commit messages readable | Yes | | |
| Significantly shorter than raw | Yes (>60% reduction) | | |
| Most recent commit visible | Yes | | |

#### 3.1.4 — Git Diff

```powershell
# If you have uncommitted changes:
rtk git diff
# Or compare two commits:
rtk git diff HEAD~3 HEAD
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| Changed files identifiable | Yes | | |
| Key changes visible | Yes | | |
| Lines added/removed shown | Yes (summary or inline) | | |
| Reduction vs baseline | >50% for large diffs | | |

#### 3.1.5 — Git Push/Commit (Informational)

```powershell
# Dry run — don't actually push. Test with a no-op commit scenario:
rtk git log --oneline -1
# Expected: minimal "ok" style output for simple operations
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| Minimal output for simple ops | "ok" or 1-line summary | | |

### 3.2 Go Build/Test

#### 3.2.1 — Go Build (Success)

```powershell
Push-Location C:\ws\K2s\k2s
rtk go build ./cmd/k2s
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| Minimal output on success | Empty or "ok" | | |
| Exit code | 0 | `$LASTEXITCODE` = | |
| Binary created | Yes (if target dir writable) | | |

#### 3.2.2 — Go Build (Failure — Error Preservation)

```powershell
rtk go build ./nonexistent/...
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| Error message present | Yes — mentions missing package | | |
| Exit code is non-zero | Yes | `$LASTEXITCODE` = | |
| **CRITICAL**: Enough info to fix the issue | Yes | | |

#### 3.2.3 — Go Test (All Passing)

```powershell
rtk go test ./internal/cli/...
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| Shows "ok" or pass summary | Yes | | |
| Significantly shorter than raw | >80% reduction | | |
| Exit code | 0 | `$LASTEXITCODE` = | |
| No individual passing test names | Correct (only summary) | | |

#### 3.2.4 — Go Test (With Failure)

```powershell
# Find a test that might fail, or create a temporary failing test:
# Option A: test a non-existent package
rtk go test ./nonexistent_test_pkg/...
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| **CRITICAL**: Failed test name visible | Yes | | |
| **CRITICAL**: Error message / assertion visible | Yes | | |
| **CRITICAL**: File:line location shown | Yes | | |
| Exit code is non-zero | Yes | `$LASTEXITCODE` = | |
| Passing tests NOT shown | Correct | | |

```powershell
Pop-Location
```

### 3.3 Kubectl / Kubernetes Operations

> Skip this section if no cluster is available (mark ⏭️).

#### 3.3.1 — kubectl Pods (Healthy Cluster)

```powershell
rtk kubectl pods
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| Pod count summary shown | "N/N healthy" | | |
| Problem pods highlighted | Yes (if any) | | |
| Reduction vs baseline | >60% | | |
| Exit code | 0 if cluster reachable | | |

#### 3.3.2 — kubectl Pods (No Cluster / Unreachable)

```powershell
# Temporarily point to invalid cluster
$env:KUBECONFIG = "C:\nonexistent\kubeconfig"
rtk kubectl pods
Remove-Item env:KUBECONFIG -ErrorAction SilentlyContinue
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| **CRITICAL**: Error message preserved | Yes — connection refused / config not found | | |
| Exit code is non-zero | Yes | `$LASTEXITCODE` = | |
| Error is actionable (tells user what's wrong) | Yes | | |

#### 3.3.3 — kubectl Apply (via TOML Filter)

```powershell
# Test with a simple manifest (dry run):
rtk kubectl apply --dry-run=client -f C:\ws\K2s\lib\manifests\coredns\coredns.yaml 2>&1
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| Created/unchanged resources shown | Yes | | |
| Errors (if any) preserved | Yes | | |
| TOML filter applied (shorter output) | Yes | | |

### 3.4 File Operations

#### 3.4.1 — Directory Listing

```powershell
rtk ls C:\ws\K2s
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| Tree-style structured output | Yes | | |
| Directory counts shown | Yes | | |
| Shorter than raw `dir` output | Yes (>50%) | | |

#### 3.4.2 — File Reading

```powershell
rtk read C:\ws\K2s\VERSION
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| File content shown | Yes — version string | | |
| Small files pass through intact | Yes | | |

#### 3.4.3 — Grep

```powershell
rtk grep "provider" C:\ws\K2s\k2s\internal\provider\
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| Results grouped by file | Yes | | |
| Match context visible | Yes | | |
| Shorter than raw grep | Yes | | |

### 3.5 SSH / Infrastructure Commands (via TOML Filter)

> These test the custom K2s TOML filters. Skip if no SSH target available.

#### 3.5.1 — Plink (PuTTY SSH)

```powershell
# If plink is available and a target VM exists:
# rtk plink -batch user@172.19.1.1 "uptime"
# Otherwise verify TOML filter syntax:
rtk --version  # Just confirm rtk runs (filter testing is passive)
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| SSH banners stripped | Yes (per ssh.toml + plink filter) | | |
| Command output preserved | Yes | | |

### 3.6 Compression Measurement

After running the above scenarios, measure overall compression:

```powershell
rtk gain
```

| Metric | Value | Pass Criteria |
|--------|-------|---------------|
| Total commands | | >10 |
| Average savings % | | >50% |
| Total tokens saved | | >0 |

```powershell
rtk gain --daily
```

Record today's specific metrics for comparison.

---

## 4. Failure & Debugging Validation

> **Critical Section**: These tests verify RTK doesn't hide important debugging information.

### 4.1 Failed Build — Error Chain Preservation

```powershell
Push-Location C:\ws\K2s\k2s

# Create a temporary file with a compile error
$testFile = "internal\cli\rtk_test_error_temp.go"
@"
package cli

func broken() {
    var x int = "not an int"  // type error
    _ = x.NonexistentMethod() // undefined method
}
"@ | Set-Content -Path $testFile

rtk go build ./internal/cli/...
$buildExitCode = $LASTEXITCODE

# Capture RTK output
$rtkOutput = rtk go build ./internal/cli/... 2>&1 | Out-String

# Cleanup
Remove-Item $testFile -Force

Pop-Location
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| **CRITICAL**: File name visible | `rtk_test_error_temp.go` | | |
| **CRITICAL**: Line numbers present | `:4:` and `:5:` (or similar) | | |
| **CRITICAL**: Error descriptions present | "cannot use" + "undefined" | | |
| **CRITICAL**: ALL errors shown (not just first) | Both errors visible | | |
| Exit code is non-zero | 1 or 2 | `$buildExitCode` = | |
| Output is still shorter than raw | Slightly compressed | | |

### 4.2 Failed Test — Assertion Message Preservation

```powershell
Push-Location C:\ws\K2s\k2s

# Create a temporary failing test
$testFile = "internal\cli\rtk_test_fail_temp_test.go"
@"
package cli

import "testing"

func TestRtkPoC_IntentionalFailure(t *testing.T) {
    expected := "hello"
    actual := "world"
    if expected != actual {
        t.Errorf("Expected %q but got %q", expected, actual)
    }
}

func TestRtkPoC_IntentionalPanic(t *testing.T) {
    var s []int
    _ = s[99]  // index out of range panic
}
"@ | Set-Content -Path $testFile

$rtkTestOutput = rtk go test ./internal/cli/... -run "TestRtkPoC" 2>&1 | Out-String
$testExitCode = $LASTEXITCODE

# Cleanup
Remove-Item $testFile -Force

Pop-Location
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| **CRITICAL**: Test name `TestRtkPoC_IntentionalFailure` visible | Yes | | |
| **CRITICAL**: Assertion message `Expected "hello" but got "world"` visible | Yes | | |
| **CRITICAL**: Test name `TestRtkPoC_IntentionalPanic` visible | Yes | | |
| **CRITICAL**: Panic info (index out of range) visible | Yes | | |
| **CRITICAL**: File:line reference visible | Yes | | |
| Exit code is non-zero | Yes | `$testExitCode` = | |
| Passing tests (if any) NOT shown | Only failures | | |

### 4.3 kubectl Failure — Permission/Connection Errors

```powershell
# Test with invalid kubeconfig
$env:KUBECONFIG = "C:\nonexistent\fake.yaml"
$rtkKubeOutput = rtk kubectl pods 2>&1 | Out-String
$kubeExitCode = $LASTEXITCODE
Remove-Item env:KUBECONFIG -ErrorAction SilentlyContinue
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| **CRITICAL**: Error type identifiable | "no such file" or "invalid config" | | |
| **CRITICAL**: Actionable error (user knows what to fix) | Yes | | |
| Exit code non-zero | Yes | `$kubeExitCode` = | |

### 4.4 Verbose Mode — Raw Output Recovery

```powershell
Push-Location C:\ws\K2s\k2s
$verboseOutput = rtk -vvv go build ./cmd/k2s 2>&1 | Out-String
Pop-Location
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| Raw command output visible | Yes (in stderr debug lines) | | |
| "Executing:" line shown | Yes (at -vv level) | | |
| Full unfiltered output at -vvv | Yes | | |
| Same info as running without rtk | Yes | | |

### 4.5 Tee System — Failure Recovery

After running a failed command (4.1 or 4.2 above):

```powershell
# Check if tee file was created
$teeDir = if ($env:LOCALAPPDATA) { "$env:LOCALAPPDATA\rtk\tee" } else { "$env:HOME/.local/share/rtk/tee" }
if (Test-Path $teeDir) {
    Get-ChildItem $teeDir -Filter "*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 3
} else {
    Write-Host "Tee directory not found (may not be created until first failure)"
}
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| Tee directory exists after failure | Yes (or "failures" config) | | |
| Log file contains full raw output | Yes (if created) | | |
| File is referenced in RTK output | Yes (path shown after failure) | | |

### 4.6 Exit Code Propagation (Comprehensive)

```powershell
# Test multiple exit code scenarios
$results = @()

# Exit 0 — success
rtk git status | Out-Null
$results += [PSCustomObject]@{Command="git status"; Expected=0; Actual=$LASTEXITCODE}

# Exit 1 — git failure
rtk git log --invalid-flag-xyz 2>&1 | Out-Null
$results += [PSCustomObject]@{Command="git log --invalid-flag"; Expected="non-zero"; Actual=$LASTEXITCODE}

# Exit 1 — go build failure
Push-Location C:\ws\K2s\k2s
rtk go build ./nonexistent/... 2>&1 | Out-Null
$results += [PSCustomObject]@{Command="go build (fail)"; Expected="non-zero"; Actual=$LASTEXITCODE}
Pop-Location

$results | Format-Table -AutoSize
```

| Command | Expected Exit Code | Actual Exit Code | Pass? |
|---------|-------------------|------------------|-------|
| `git status` (success) | 0 | | |
| `git log --invalid-flag` | non-zero | | |
| `go build` (nonexistent) | non-zero | | |

**PASS Criteria**: ALL exit codes must match expected. Any mismatch is a **blocking failure**.

---

## 5. Observability Validation

### 5.1 Token Tracking Database

```powershell
# Verify tracking database exists after running commands
$dbPath = if ($env:APPDATA) { "$env:APPDATA\rtk\tracking.db" } else { "$env:HOME/.local/share/rtk/tracking.db" }
Test-Path $dbPath
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| Database file exists | True | | |
| `rtk gain` shows non-zero data | Yes — commands counted | | |

### 5.2 RTK Gain Output Validation

```powershell
rtk gain
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| Total commands shown | >0 (after running Section 3-4) | | |
| Average savings % shown | >0% | | |
| Total tokens saved shown | >0 | | |

```powershell
rtk gain --daily
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| Today's date shown | Yes | | |
| Daily breakdown present | Yes | | |

```powershell
rtk gain --all --format json | ConvertFrom-Json
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| Valid JSON output | Yes (parses without error) | | |
| Contains total_commands field | Yes | | |
| Contains total_saved field | Yes | | |

### 5.3 Prometheus Metrics Exporter

```powershell
# Run exporter once (not as loop) to test metric generation
cd C:\ws\K2s\docs\dev-guide\rtk-poc\scripts

# Test metric generation by sourcing the function
. .\Start-RtkMetricsExporter.ps1 -Mode textfile -IntervalSeconds 9999 &
Start-Sleep -Seconds 3
Stop-Job -Id (Get-Job | Select-Object -Last 1).Id -ErrorAction SilentlyContinue

# Or directly test:
$metricsOutput = & {
    . .\Start-RtkMetricsExporter.ps1  # This won't work perfectly in isolation
}

# Alternative: just start it and check the output file
Start-Process powershell -ArgumentList "-File `"$PWD\Start-RtkMetricsExporter.ps1`" -Mode textfile -IntervalSeconds 5" -NoNewWindow
Start-Sleep -Seconds 8
$metricsContent = Get-Content $env:TEMP\rtk_metrics.prom -Raw -ErrorAction SilentlyContinue
Write-Host $metricsContent
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| .prom file created | Yes at `$env:TEMP\rtk_metrics.prom` | | |
| Contains `rtk_exporter_up 1` | Yes | | |
| Contains `rtk_commands_total` | Yes | | |
| Contains `rtk_tokens_saved_total` | Yes | | |
| Contains `rtk_compression_ratio` | Yes (value < 1.0) | | |
| Contains `rtk_info` with version label | Yes | | |
| All values are numeric (not NaN) | Yes | | |

### 5.4 RTK Discover (Missed Opportunities)

```powershell
rtk discover
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| Shows any missed commands | Maybe (depends on shell history) | | |
| Output is actionable | Yes — suggests rtk equivalents | | |

### 5.5 Grafana Dashboard Import Test

```powershell
# Verify dashboard JSON is valid
$dashboard = Get-Content "C:\ws\K2s\docs\dev-guide\rtk-poc\grafana\rtk-dashboard.json" -Raw | ConvertFrom-Json
Write-Host "Dashboard: $($dashboard.title)"
Write-Host "Panels: $(($dashboard.panels | Where-Object { $_.type -ne 'row' }).Count)"
Write-Host "UID: $($dashboard.uid)"
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| JSON parses without error | Yes | | |
| Title is present | "RTK PoC — Token Optimization (K2s)" | | |
| Panel count > 5 | Yes | | |
| UID is `rtk-poc-k2s` | Yes | | |

---

## 6. AI Workflow Validation

### 6.1 Baseline: AI Agent Without RTK

Perform a typical AI-assisted task **without** RTK and note:

| Observation | Without RTK |
|-------------|-------------|
| Terminal output tokens sent to AI (estimate) | |
| Context window pressure (rough %) | |
| AI response quality (1-5) | |
| Times AI said "output too long" or truncated | |
| Number of iterations to complete task | |
| Agent premium requests consumed | |

**Suggested task**: "Fix a compile error in K2s Go code" — involving `go build`, `git diff`, and editing.

### 6.2 Same Task: AI Agent With RTK

Perform the same type of task **with** RTK prefix on all terminal commands:

```
Use rtk prefix for: go build, go test, git status, git diff, kubectl commands
```

| Observation | With RTK |
|-------------|----------|
| Terminal output tokens sent to AI (estimate) | |
| Context window pressure (rough %) | |
| AI response quality (1-5) | |
| Times AI said "output too long" or truncated | |
| Number of iterations to complete task | |
| Agent premium requests consumed | |

### 6.3 Comparison Analysis

| Metric | Without RTK | With RTK | Delta | Pass? |
|--------|-------------|----------|-------|-------|
| Estimated tokens consumed | | | | Reduction >50% |
| AI response quality | | | | Same or better |
| Iterations needed | | | | Same or fewer |
| Context overflow events | | | | Fewer or zero |
| Debugging ability | | | | Not degraded |

### 6.4 Long-Session Test

Use RTK for an extended coding session (>30 min) and note:

| Observation | Value |
|-------------|-------|
| Session duration | |
| Total rtk commands used | |
| `rtk gain` reported savings for session | |
| Any context overflow prevented | |
| Any debugging issue caused by RTK | |
| Overall experience (1-5) | |

---

## 7. Rollback Validation

### 7.1 Level 1: Per-Command Bypass

```powershell
# Run same command with and without rtk
git status          # Raw — works normally
rtk git status      # With RTK — compressed
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| Raw command unaffected by RTK | Yes — normal output | | |
| No interference between modes | Yes | | |

### 7.2 Level 2: Session Disable

```powershell
$env:RTK_DISABLED = "1"
rtk git status      # Should pass through unfiltered
rtk go test ./k2s/internal/cli/... 2>&1 | Out-String | Measure-Object -Character
Remove-Item env:RTK_DISABLED
rtk go test ./k2s/internal/cli/... 2>&1 | Out-String | Measure-Object -Character
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| RTK_DISABLED=1 → unfiltered output | Same as raw command | | |
| After removing env var → filtered again | Shorter output | | |

### 7.3 Level 3: Verbose Bypass

```powershell
rtk -vvv git log -5
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| Full raw output visible in stderr | Yes — debug lines | | |
| Can see exactly what was filtered | Yes | | |

### 7.4 Level 4: Full Uninstall

```powershell
# Test uninstall (DO THIS LAST or reinstall after)
cd C:\ws\K2s\docs\dev-guide\rtk-poc\scripts
.\Uninstall-Rtk.ps1 -KeepData   # Keep tracking data for analysis
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| Binary removed | `Get-Command rtk` fails | | |
| Config removed | `$env:APPDATA\rtk\config.toml` gone | | |
| PATH cleaned | Install dir removed from PATH | | |
| .rtk/filters.toml still present | Yes (inert without binary) | | |
| All normal commands work | Yes — no side effects | | |

```powershell
# REINSTALL after testing uninstall:
.\Install-Rtk.ps1 -Force
```

### 7.5 Cleanup Verification

```powershell
# After uninstall, verify no RTK artifacts interfere
git status          # Works
go build ./k2s/cmd/k2s   # Works
kubectl get pods    # Works (if cluster available)
```

| Criterion | Expected | Actual | Pass? |
|-----------|----------|--------|-------|
| No "rtk not found" errors anywhere | Yes | | |
| No PATH remnants | Yes | | |
| No background processes | Yes | | |

---

## 8. Final PoC Evaluation

### 8.1 Quantitative Results

Fill in after completing all tests:

| Metric | Minimum Required | Target | Actual | Pass? |
|--------|-----------------|--------|--------|-------|
| Average token savings | >50% | >75% | | |
| Commands processed | >10 | >30 | | |
| Critical info preserved | 100% | 100% | | |
| Exit code accuracy | 100% | 100% | | |
| Overhead (avg) | <50ms | <15ms | | |
| Debugging regressions | 0 | 0 | | |
| Tee recovery works | Yes | Yes | | |
| Verbose bypass works | Yes | Yes | | |

### 8.2 Qualitative Results

| Criterion | Rating (1-5) | Notes |
|-----------|-------------|-------|
| Developer experience | | |
| AI response quality with RTK | | |
| Debugging ability | | |
| Workflow friction | | |
| Would recommend continuing | | |
| Overall value assessment | | |

### 8.3 Risk Assessment (Post-PoC)

| Risk | Observed? | Severity | Notes |
|------|-----------|----------|-------|
| Error info hidden | | | |
| Debugging difficulty | | | |
| Workflow friction | | | |
| Performance impact | | | |
| Reliability issues | | | |

### 8.4 Optimization Results Summary

| Command Category | Raw Tokens (Avg) | RTK Tokens (Avg) | Savings % | Verdict |
|-----------------|------------------|-------------------|-----------|---------|
| Git operations | | | | |
| Go build | | | | |
| Go test | | | | |
| kubectl | | | | |
| File operations | | | | |
| **Overall** | | | | |

### 8.5 Decision Recommendation

Based on the data collected, check ONE:

- [ ] **EXPAND**: Savings >65%, zero regressions, satisfaction ≥4/5 → Recommend team-wide rollout
- [ ] **CONTINUE**: Savings 40-65% or satisfaction 3-4/5 → Extend PoC 2 more weeks, tune filters
- [ ] **OPTIONAL**: Savings >50% but mixed feedback → Keep as optional developer tool
- [ ] **REJECT**: Savings <40% OR debugging regressions OR satisfaction <3/5 → Uninstall, document learnings

### 8.6 Recommendations for Next Phase

If EXPAND or CONTINUE:
- [ ] Commit `.rtk/filters.toml` to repository
- [ ] Add RTK guidance to `copilot-instructions.md`
- [ ] Consider vendoring `rtk.exe` in `bin/` directory
- [ ] Set up persistent Prometheus/Grafana monitoring
- [ ] Schedule bi-weekly filter review
- [ ] Establish feedback channel for ongoing issues

If REJECT:
- [ ] Run `Uninstall-Rtk.ps1`
- [ ] Remove `.rtk/` directory from repo
- [ ] Document learnings in ADR (Architecture Decision Record)
- [ ] Re-evaluate in 6 months if RTK adds features addressing gaps

---

## Troubleshooting

### RTK Not Found

```powershell
# Check PATH
$env:PATH -split ';' | Where-Object { Test-Path (Join-Path $_ "rtk.exe") }

# Direct path check
Test-Path "$env:USERPROFILE\.local\bin\rtk.exe"

# Fix: reinstall
.\Install-Rtk.ps1 -Force
```

### RTK Crashes/Hangs

```powershell
# Bypass immediately
git status    # Use raw command

# Check version
rtk --version

# If rtk hangs on specific command, add to exclude list in config:
# Edit $env:APPDATA\rtk\config.toml:
# [hooks]
# exclude_commands = ["problematic-command"]
```

### No Token Savings Showing

```powershell
# Run a few commands first
rtk git status
rtk git log -5

# Check gain
rtk gain

# If still empty, check tracking DB
$dbPath = "$env:APPDATA\rtk\tracking.db"
Test-Path $dbPath
(Get-Item $dbPath).Length  # Should be > 0
```

### TOML Filter Not Applied

```powershell
# Enable TOML debug mode
$env:RTK_TOML_DEBUG = "1"
rtk git status    # Should show which filter matched in stderr
Remove-Item env:RTK_TOML_DEBUG

# Verify filter file
Get-Content C:\ws\K2s\.rtk\filters.toml | Select-Object -First 5

# Check if rtk is running from K2s directory (filters are CWD-relative)
Get-Location
```

### Metrics Exporter Issues

```powershell
# Test manually
rtk gain --all --format json

# If JSON parsing fails, check rtk version supports --format json
rtk gain --help

# Check exporter output file
Get-Content $env:TEMP\rtk_metrics.prom -ErrorAction SilentlyContinue
```

### Build/Test Errors After RTK Install

```powershell
# RTK does NOT modify your code or build system.
# If builds fail, it's unrelated to RTK.
# Verify by running WITHOUT rtk prefix:
go build ./k2s/cmd/k2s    # Same error? RTK is not the cause.
```

---

## Observations Log

Use this section to record daily observations during the PoC:

### Day 1: ____/____/2026
- Commands used with RTK: ___
- Notable savings: ___
- Issues encountered: ___
- Debugging quality: ___/5

### Day 2: ____/____/2026
- Commands used with RTK: ___
- Notable savings: ___
- Issues encountered: ___
- Debugging quality: ___/5

### Day 3: ____/____/2026
- Commands used with RTK: ___
- Notable savings: ___
- Issues encountered: ___
- Debugging quality: ___/5

### Day 4: ____/____/2026
- Commands used with RTK: ___
- Notable savings: ___
- Issues encountered: ___
- Debugging quality: ___/5

### Day 5: ____/____/2026
- Commands used with RTK: ___
- Notable savings: ___
- Issues encountered: ___
- Debugging quality: ___/5

---

## Sign-Off

| Role | Name | Date | Signature |
|------|------|------|-----------|
| PoC Lead | | | ☐ Tests complete |
| Developer 1 | | | ☐ Participated |
| Developer 2 | | | ☐ Participated |
| Decision | | | ☐ Expand / ☐ Continue / ☐ Optional / ☐ Reject |

