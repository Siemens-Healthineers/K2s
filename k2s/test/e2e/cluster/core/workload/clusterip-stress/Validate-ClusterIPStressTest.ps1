# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Validates ClusterIP allocation after stress test deployment.

.DESCRIPTION
This script verifies:
1. All ClusterIP services received unique, non-duplicate IPs
2. All headless services correctly have ClusterIP = None
3. No service is stuck without a ClusterIP assignment
4. The clusterip-webhook pod is healthy

Deploy the stress test manifests first:
  kubectl apply -k k2s/test/e2e/cluster/core/workload/clusterip-stress/

Cleanup after testing:
  kubectl delete namespace clusterip-stress-test

.EXAMPLE
kubectl apply -k k2s/test/e2e/cluster/core/workload/clusterip-stress/
powershell -File Validate-ClusterIPStressTest.ps1
kubectl delete namespace clusterip-stress-test
#>

param(
    [string]$Namespace = 'clusterip-stress-test',
    [int]$ExpectedClusterIPServices = 20,
    [int]$ExpectedHeadlessServices = 6
)

$ErrorActionPreference = 'Stop'

function Invoke-Kubectl {
    param([string[]]$Arguments)
    $output = & kubectl @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAIL: kubectl $($Arguments -join ' ') failed (exit code $LASTEXITCODE):" -ForegroundColor Red
        Write-Host ($output | Out-String) -ForegroundColor Red
        exit 1
    }
    return $output
}

Write-Host "======================================"
Write-Host " ClusterIP Stress Test Validation"
Write-Host "======================================"
Write-Host ""

# 1. Check webhook pod health
Write-Host "[1/4] Checking clusterip-webhook pod health..."
$raw = Invoke-Kubectl -Arguments @('get', 'pods', '-n', 'k2s-webhook', '-l', 'app.kubernetes.io/name=clusterip-webhook', '-o', 'json')
$webhookPod = $raw | ConvertFrom-Json
if ($webhookPod.items.Count -eq 0) {
    Write-Host "FAIL: No clusterip-webhook pod found in k2s-webhook namespace" -ForegroundColor Red
    exit 1
}
$notReady = @($webhookPod.items | Where-Object {
    $_.status.phase -ne 'Running' -or
    ($_.status.conditions | Where-Object { $_.type -eq 'Ready' }).status -ne 'True'
})
if ($notReady.Count -gt 0) {
    Write-Host "FAIL: $($notReady.Count) webhook pod(s) not Ready:" -ForegroundColor Red
    $notReady | ForEach-Object { Write-Host "  - $($_.metadata.name): phase=$($_.status.phase)" -ForegroundColor Red }
    exit 1
}
Write-Host "  OK: All $($webhookPod.items.Count) webhook pod(s) Running and Ready"

# 2. Get all services in the stress test namespace (with readiness wait)
Write-Host ""
Write-Host "[2/4] Collecting services in namespace '$Namespace'..."

$maxAttempts = 12
$waitSeconds = 5
$allServices = @()
$pendingSvcs = @()
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    $output = & kubectl get svc -n $Namespace -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ($attempt -lt $maxAttempts) {
            Write-Host "  Waiting for namespace/services (attempt $attempt/$maxAttempts): kubectl returned exit code $LASTEXITCODE"
            Start-Sleep -Seconds $waitSeconds
            continue
        }
        Write-Host "FAIL: kubectl get svc -n $Namespace failed after $maxAttempts attempts:" -ForegroundColor Red
        Write-Host ($output | Out-String) -ForegroundColor Red
        exit 1
    }

    $services = $output | ConvertFrom-Json
    $allServices = $services.items

    $nonHeadlessSvcs = @($allServices | Where-Object { $_.spec.clusterIP -ne 'None' })
    $pendingSvcs = @($nonHeadlessSvcs | Where-Object { [string]::IsNullOrEmpty($_.spec.clusterIP) })

    if ($allServices.Count -ge ($ExpectedClusterIPServices + $ExpectedHeadlessServices) -and $pendingSvcs.Count -eq 0) {
        break
    }

    if ($attempt -lt $maxAttempts) {
        Write-Host "  Waiting for services to be ready (attempt $attempt/$maxAttempts, found $($allServices.Count) services, $($pendingSvcs.Count) pending IP)..."
        Start-Sleep -Seconds $waitSeconds
    }
}

if ($pendingSvcs.Count -gt 0 -or $allServices.Count -lt ($ExpectedClusterIPServices + $ExpectedHeadlessServices)) {
    Write-Host "FAIL: Timed out waiting for services to be ready after $(($maxAttempts - 1) * $waitSeconds)s." -ForegroundColor Red
    Write-Host "  Expected $($ExpectedClusterIPServices + $ExpectedHeadlessServices) services, found $($allServices.Count). Pending IPs: $($pendingSvcs.Count)." -ForegroundColor Red
    exit 1
}

Write-Host "  Found $($allServices.Count) services total"

# 3. Validate ClusterIP services have unique IPs
Write-Host ""
Write-Host "[3/4] Validating ClusterIP uniqueness..."
$nonHeadlessSvcs = @($allServices | Where-Object { $_.spec.clusterIP -ne 'None' })

Write-Host "  ClusterIP services: $($nonHeadlessSvcs.Count) (expected: $ExpectedClusterIPServices)"

if ($nonHeadlessSvcs.Count -ne $ExpectedClusterIPServices) {
    Write-Host "FAIL: Expected $ExpectedClusterIPServices ClusterIP services, got $($nonHeadlessSvcs.Count)" -ForegroundColor Red
    exit 1
}

# Check for empty/missing ClusterIPs (defense-in-depth after wait loop)
$missingIP = @($nonHeadlessSvcs | Where-Object { [string]::IsNullOrEmpty($_.spec.clusterIP) })
if ($missingIP.Count -gt 0) {
    Write-Host "FAIL: $($missingIP.Count) services have no ClusterIP assigned:" -ForegroundColor Red
    $missingIP | ForEach-Object { Write-Host "  - $($_.metadata.name)" -ForegroundColor Red }
    exit 1
}

$clusterIPServices = $nonHeadlessSvcs

# Check for duplicate ClusterIPs (THE critical check that would have caught the bug)
$ipMap = @{}
$duplicates = @()
foreach ($svc in $clusterIPServices) {
    $ip = $svc.spec.clusterIP
    $name = $svc.metadata.name
    if ($ipMap.ContainsKey($ip)) {
        $ipMap[$ip] += @($name)
    } else {
        $ipMap[$ip] = @($name)
    }
}
foreach ($entry in $ipMap.GetEnumerator()) {
    if ($entry.Value.Count -gt 1) {
        $duplicates += "  DUPLICATE: $($entry.Key) assigned to: $($entry.Value -join ', ')"
    }
}

if ($duplicates.Count -gt 0) {
    Write-Host "FAIL: Duplicate ClusterIP allocations detected!" -ForegroundColor Red
    $duplicates | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    Write-Host ""
    Write-Host "All ClusterIP assignments:"
    foreach ($svc in $clusterIPServices) {
        Write-Host "  $($svc.metadata.name) = $($svc.spec.clusterIP)"
    }
    exit 1
}

Write-Host "  OK: All $($clusterIPServices.Count) ClusterIPs are unique"
Write-Host ""
Write-Host "  Assigned IPs:"
foreach ($svc in ($clusterIPServices | Sort-Object {
    $parts = $_.spec.clusterIP -split '\.'
    [version]"$($parts[0]).$($parts[1]).$($parts[2]).$($parts[3])"
})) {
    Write-Host "    $($svc.spec.clusterIP) -> $($svc.metadata.name)"
}

# 4. Validate headless services
Write-Host ""
Write-Host "[4/4] Validating headless services..."

# Check services that should be headless (by name) directly from $allServices
$badHeadless = @($allServices | Where-Object {
    $_.metadata.name -like 'stress-headless-*' -and $_.spec.clusterIP -ne 'None'
})
if ($badHeadless.Count -gt 0) {
    Write-Host "FAIL: Headless services incorrectly received a ClusterIP:" -ForegroundColor Red
    $badHeadless | ForEach-Object { Write-Host "  - $($_.metadata.name): $($_.spec.clusterIP)" -ForegroundColor Red }
    exit 1
}

$actualHeadless = @($allServices | Where-Object { $_.metadata.name -like 'stress-headless-*' })
if ($actualHeadless.Count -ne $ExpectedHeadlessServices) {
    Write-Host "FAIL: Expected $ExpectedHeadlessServices headless services, got $($actualHeadless.Count)" -ForegroundColor Red
    exit 1
}
Write-Host "  OK: All $($actualHeadless.Count) headless services have ClusterIP=None"

# Summary
Write-Host ""
Write-Host "======================================"
Write-Host " ALL CHECKS PASSED"
Write-Host "======================================"
Write-Host ""
Write-Host " ClusterIP services: $($clusterIPServices.Count) (all unique)"
Write-Host " Headless services:  $($actualHeadless.Count) (all None)"
Write-Host " Webhook pod:        Running/Ready"
Write-Host ""
exit 0
