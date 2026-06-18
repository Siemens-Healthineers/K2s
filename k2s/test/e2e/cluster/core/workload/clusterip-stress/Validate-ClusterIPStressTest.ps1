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

Run this after deploying the clusterip-stress manifests.

.EXAMPLE
powershell -File Validate-ClusterIPStressTest.ps1
#>

param(
    [string]$Namespace = 'clusterip-stress-test',
    [int]$ExpectedClusterIPServices = 20,
    [int]$ExpectedHeadlessServices = 4
)

$ErrorActionPreference = 'Stop'

Write-Host "======================================"
Write-Host " ClusterIP Stress Test Validation"
Write-Host "======================================"
Write-Host ""

# 1. Check webhook pod health
Write-Host "[1/4] Checking clusterip-webhook pod health..."
$webhookPod = kubectl get pods -n k2s-webhook -l app.kubernetes.io/name=clusterip-webhook -o json | ConvertFrom-Json
if ($webhookPod.items.Count -eq 0) {
    Write-Error "FAIL: No clusterip-webhook pod found in k2s-webhook namespace"
    exit 1
}
$podStatus = $webhookPod.items[0].status.phase
$podReady = ($webhookPod.items[0].status.conditions | Where-Object { $_.type -eq 'Ready' }).status
if ($podStatus -ne 'Running' -or $podReady -ne 'True') {
    Write-Error "FAIL: Webhook pod is not Ready (phase=$podStatus, ready=$podReady)"
    exit 1
}
Write-Host "  OK: Webhook pod is Running and Ready"

# 2. Get all services in the stress test namespace
Write-Host ""
Write-Host "[2/4] Collecting services in namespace '$Namespace'..."
$services = kubectl get svc -n $Namespace -o json | ConvertFrom-Json
$allServices = $services.items

if ($allServices.Count -eq 0) {
    Write-Error "FAIL: No services found in namespace $Namespace"
    exit 1
}
Write-Host "  Found $($allServices.Count) services total"

# 3. Validate ClusterIP services have unique IPs
Write-Host ""
Write-Host "[3/4] Validating ClusterIP uniqueness..."
$clusterIPServices = $allServices | Where-Object { $_.spec.clusterIP -ne 'None' }
$headlessServices = $allServices | Where-Object { $_.spec.clusterIP -eq 'None' }

Write-Host "  ClusterIP services: $($clusterIPServices.Count) (expected: $ExpectedClusterIPServices)"
Write-Host "  Headless services:  $($headlessServices.Count) (expected: $ExpectedHeadlessServices)"

if ($clusterIPServices.Count -ne $ExpectedClusterIPServices) {
    Write-Error "FAIL: Expected $ExpectedClusterIPServices ClusterIP services, got $($clusterIPServices.Count)"
    exit 1
}

# Check for empty/missing ClusterIPs
$missingIP = $clusterIPServices | Where-Object { [string]::IsNullOrEmpty($_.spec.clusterIP) }
if ($missingIP.Count -gt 0) {
    Write-Error "FAIL: $($missingIP.Count) services have no ClusterIP assigned:"
    $missingIP | ForEach-Object { Write-Error "  - $($_.metadata.name)" }
    exit 1
}

# Check for duplicate ClusterIPs (THE critical check that would have caught the bug)
$ipMap = @{}
$duplicates = @()
foreach ($svc in $clusterIPServices) {
    $ip = $svc.spec.clusterIP
    $name = $svc.metadata.name
    if ($ipMap.ContainsKey($ip)) {
        $duplicates += "  DUPLICATE: $ip assigned to both '$($ipMap[$ip])' and '$name'"
    }
    $ipMap[$ip] = $name
}

if ($duplicates.Count -gt 0) {
    Write-Error "FAIL: Duplicate ClusterIP allocations detected!"
    $duplicates | ForEach-Object { Write-Error $_ }
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
foreach ($svc in ($clusterIPServices | Sort-Object { $_.spec.clusterIP })) {
    Write-Host "    $($svc.spec.clusterIP) -> $($svc.metadata.name)"
}

# 4. Validate headless services
Write-Host ""
Write-Host "[4/4] Validating headless services..."
if ($headlessServices.Count -ne $ExpectedHeadlessServices) {
    Write-Error "FAIL: Expected $ExpectedHeadlessServices headless services, got $($headlessServices.Count)"
    exit 1
}

$badHeadless = $headlessServices | Where-Object { $_.spec.clusterIP -ne 'None' }
if ($badHeadless.Count -gt 0) {
    Write-Error "FAIL: Headless services incorrectly received a ClusterIP:"
    $badHeadless | ForEach-Object { Write-Error "  - $($_.metadata.name): $($_.spec.clusterIP)" }
    exit 1
}
Write-Host "  OK: All $($headlessServices.Count) headless services have ClusterIP=None"

# Summary
Write-Host ""
Write-Host "======================================"
Write-Host " ALL CHECKS PASSED"
Write-Host "======================================"
Write-Host ""
Write-Host " ClusterIP services: $($clusterIPServices.Count) (all unique)"
Write-Host " Headless services:  $($headlessServices.Count) (all None)"
Write-Host " Webhook pod:        Running/Ready"
Write-Host ""
exit 0
