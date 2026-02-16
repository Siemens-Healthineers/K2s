# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#[
.SYNOPSIS
Backs up dashboard configuration (metadata-only)

.DESCRIPTION
Captures the dashboard addon restore-relevant configuration without exporting Helm-managed resources.
Currently this is metadata-only and records:
- selected ingress integration (none/nginx/traefik/nginx-gw)
- whether the metrics addon is enabled

The CLI wraps the staging folder into a zip archive.

.PARAMETER BackupDir
Destination directory for backup artifacts.

.EXAMPLE
powershell <installation folder>\addons\dashboard\Backup.ps1 -BackupDir C:\Temp\dashboard-backup
#>
Param(
    [parameter(Mandatory = $true, HelpMessage = 'Directory where backup files will be written')]
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

Import-Module $infraModule, $clusterModule, $addonsModule

Initialize-Logging -ShowLogs:$ShowLogs

function Fail([string]$errMsg, [string]$code = 'addon-backup-failed') {
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code $code -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Write-Log "[DashboardBackup] Backing up addon 'dashboard'" -Console

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    Fail $systemError.Message 'system-not-available'
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{ Name = 'dashboard' })) -ne $true) {
    Fail "Addon 'dashboard' is not enabled. Enable it before running backup." 'addon-not-enabled'
}

$nsCheck = Invoke-Kubectl -Params 'get', 'ns', 'dashboard'
if (-not $nsCheck.Success) {
    Fail "Namespace 'dashboard' not found. Is addon 'dashboard' installed? Details: $($nsCheck.Output)" 'namespace-not-found'
}

New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null

# Detect current ingress integration (best-effort)
$ingress = 'none'
try {
    $nginxIngress = (Invoke-Kubectl -Params '-n', 'dashboard', 'get', 'ingress', 'dashboard-nginx-cluster-local', '--ignore-not-found').Output
    if ($nginxIngress) {
        $ingress = 'nginx'
    }
    else {
        $traefikIngress = (Invoke-Kubectl -Params '-n', 'dashboard', 'get', 'ingress', 'dashboard-traefik-cluster-local', '--ignore-not-found').Output
        if ($traefikIngress) {
            $ingress = 'traefik'
        }
        else {
            $gwRoute = (Invoke-Kubectl -Params '-n', 'dashboard', 'get', 'httproute', 'dashboard-nginx-gw-cluster-local', '--ignore-not-found').Output
            if ($gwRoute) {
                $ingress = 'nginx-gw'
            }
        }
    }
}
catch {
    Write-Log "[DashboardBackup] Note: Failed to auto-detect ingress integration: $($_.Exception.Message)" -Console
}

$metricsEnabled = $false
try {
    $metricsEnabled = (Test-IsAddonEnabled -Addon ([pscustomobject] @{ Name = 'metrics' })) -eq $true
}
catch {
    $metricsEnabled = $false
}

$version = 'unknown'
try { $version = Get-ConfigProductVersion } catch { }

$manifest = [pscustomobject]@{
    k2sVersion    = $version
    addon         = 'dashboard'
    files         = @()
    createdAt     = (Get-Date).ToString('o')
    ingress       = $ingress
    enableMetrics = $metricsEnabled
}

$manifestPath = Join-Path $BackupDir 'backup.json'
$manifest | ConvertTo-Json -Depth 20 | Set-Content -Path $manifestPath -Encoding UTF8 -Force

Write-Log "[DashboardBackup] Wrote metadata-only backup to '$BackupDir' (ingress=$ingress, enableMetrics=$metricsEnabled)" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
