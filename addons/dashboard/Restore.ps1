# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#[
.SYNOPSIS
Restores dashboard configuration from a backup staging folder

.DESCRIPTION
This restore is configs-only and does not attempt to restore Helm-managed dashboard resources.
It restores:
- ingress integration choice (none/nginx/traefik/nginx-gw)
- whether metrics addon should be enabled

After applying the desired ingress integration, it runs Update.ps1 to (re)generate ephemeral
auth wiring (bearer-token middleware/patch) and service-mesh patches based on current cluster state.

.PARAMETER BackupDir
Directory containing extracted backup artifacts (including backup.json).
#>
Param(
    [parameter(Mandatory = $true, HelpMessage = 'Directory where backup files were extracted')]
    [string] $BackupDir,

    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,

    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,

    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$dashboardModule = "$PSScriptRoot\dashboard.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule, $dashboardModule

Initialize-Logging -ShowLogs:$ShowLogs

function Fail([string]$errMsg, [string]$code = 'addon-restore-failed') {
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code $code -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Write-Log "[DashboardRestore] Restoring addon 'dashboard' from '$BackupDir'" -Console

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    Fail $systemError.Message 'system-not-available'
}

if (-not (Test-Path -Path $BackupDir)) {
    Fail "BackupDir '$BackupDir' does not exist." 'backupdir-not-found'
}

$manifestPath = Join-Path $BackupDir 'backup.json'
if (-not (Test-Path -Path $manifestPath)) {
    Fail "Missing backup.json in '$BackupDir'" 'manifest-missing'
}

$manifest = $null
try {
    $manifest = (Get-Content -Path $manifestPath -Raw) | ConvertFrom-Json
}
catch {
    Fail "Failed to parse backup.json: $($_.Exception.Message)" 'manifest-invalid'
}

$desiredIngress = 'none'
if ($manifest.PSObject.Properties.Name -contains 'ingress') {
    $desiredIngress = [string]$manifest.ingress
}

$desiredEnableMetrics = $false
if ($manifest.PSObject.Properties.Name -contains 'enableMetrics') {
    $desiredEnableMetrics = [bool]$manifest.enableMetrics
}

# Normalize (Windows PowerShell 5.1 compatible)
if ([string]::IsNullOrWhiteSpace($desiredIngress)) {
    $desiredIngress = 'none'
}
else {
    $desiredIngress = $desiredIngress.Trim().ToLowerInvariant()
}
if ($desiredIngress -notin @('none', 'nginx', 'traefik', 'nginx-gw')) {
    Write-Log "[DashboardRestore] Unknown ingress '$desiredIngress' in backup.json; falling back to 'none'" -Console
    $desiredIngress = 'none'
}

try {
    if ($desiredEnableMetrics -eq $true) {
        if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{ Name = 'metrics' })) -ne $true) {
            Write-Log "[DashboardRestore] Enabling metrics addon (requested by backup)" -Console
            &"$PSScriptRoot\..\metrics\Enable.ps1" -ShowLogs:$ShowLogs
        }
        else {
            Write-Log "[DashboardRestore] Metrics addon already enabled" -Console
        }
    }

    if ($desiredIngress -ne 'none') {
        Write-Log "[DashboardRestore] Ensuring ingress addon '$desiredIngress' is enabled" -Console
        Enable-IngressAddon -Ingress:$desiredIngress
    }

    Write-Log "[DashboardRestore] Applying dashboard ingress integration (preferred: $desiredIngress)" -Console
    &"$PSScriptRoot\Update.ps1" -PreferredIngress $desiredIngress

    Write-Log "[DashboardRestore] Waiting for dashboard to become ready" -Console
    $ok = Wait-ForDashboardAvailable
    if (-not $ok) {
        throw "Dashboard pods did not become ready after restore."
    }
}
catch {
    Fail "Restore of addon 'dashboard' failed: $($_.Exception.Message)"
}

Write-Log "[DashboardRestore] Restore finished" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
