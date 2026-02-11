# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#[
.SYNOPSIS
Restores logging configuration

.DESCRIPTION
Restores selected ConfigMaps (best-effort). Optionally restarts workloads to pick up configuration changes.

.PARAMETER BackupDir
Directory containing extracted backup artifacts (staging folder).

.EXAMPLE
powershell <installation folder>\addons\logging\Restore.ps1 -BackupDir C:\Temp\logging-restore
#>
Param(
    [parameter(Mandatory = $true, HelpMessage = 'Back-up directory to restore data from.')]
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

$namespace = 'logging'
$opensearchStatefulSet = 'opensearch-cluster-master'
$dashboardsDeployment = 'opensearch-dashboards'

function Fail([string]$errMsg) {
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-restore-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

function Try-ApplyConfigMapFile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $leaf = Split-Path -Leaf $Path
    Write-Log "[LoggingRestore] Applying '$leaf'" -Console

    $result = Invoke-Kubectl -Params 'apply', '-f', $Path
    if (-not $result.Success) {
        Write-Log "[LoggingRestore] Warning: failed to apply '$leaf': $($result.Output)" -Console
    }
}

function Try-RolloutRestart {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Kind,
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [Parameter(Mandatory = $true)]
        [string] $Namespace
    )

    $check = Invoke-Kubectl -Params 'get', $Kind, $Name, '-n', $Namespace
    if (-not $check.Success) {
        return
    }

    $restart = Invoke-Kubectl -Params 'rollout', 'restart', $Kind, $Name, '-n', $Namespace
    if (-not $restart.Success) {
        Write-Log "[LoggingRestore] Warning: rollout restart failed for ${Kind}/${Name}: $($restart.Output)" -Console
    }
}

function Try-RolloutStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Kind,
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [Parameter(Mandatory = $true)]
        [string] $Namespace
    )

    $check = Invoke-Kubectl -Params 'get', $Kind, $Name, '-n', $Namespace
    if (-not $check.Success) {
        return
    }

    $status = Invoke-Kubectl -Params 'rollout', 'status', $Kind, $Name, '-n', $Namespace, '--timeout=600s'
    if (-not $status.Success) {
        Write-Log "[LoggingRestore] Warning: rollout status failed for ${Kind}/${Name}: $($status.Output)" -Console
    }
}

Write-Log "[LoggingRestore] Restoring addon 'logging' from '$BackupDir'" -Console

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    Fail $systemError.Message
}

if (-not (Test-Path -LiteralPath $BackupDir)) {
    Fail "BackupDir not found: $BackupDir"
}

$filesToApply = @(
    (Join-Path $BackupDir 'opensearch-config.json'),
    (Join-Path $BackupDir 'fluent-bit-config.json'),
    (Join-Path $BackupDir 'fluent-bit-win-parsers.json'),
    (Join-Path $BackupDir 'fluent-bit-win-config.json')
)

if (($filesToApply | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0) {
    Write-Log "[LoggingRestore] No config files found in backup; nothing to restore (enable-only restore)." -Console
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
    }
    return
}

try {
    # Best-effort restore of config
    foreach ($f in $filesToApply) {
        Try-ApplyConfigMapFile -Path $f
    }

    # Best-effort restart so pods pick up updated ConfigMaps
    Try-RolloutRestart -Kind 'statefulset' -Name $opensearchStatefulSet -Namespace $namespace
    Try-RolloutRestart -Kind 'deployment' -Name $dashboardsDeployment -Namespace $namespace
    Try-RolloutRestart -Kind 'daemonset' -Name 'fluent-bit' -Namespace $namespace
    Try-RolloutRestart -Kind 'daemonset' -Name 'fluent-bit-win' -Namespace $namespace

    Write-Log "[LoggingRestore] Waiting for workloads to be ready (best-effort)" -Console
    Try-RolloutStatus -Kind 'statefulset' -Name $opensearchStatefulSet -Namespace $namespace
    Try-RolloutStatus -Kind 'deployment' -Name $dashboardsDeployment -Namespace $namespace
    Try-RolloutStatus -Kind 'daemonset' -Name 'fluent-bit' -Namespace $namespace
    Try-RolloutStatus -Kind 'daemonset' -Name 'fluent-bit-win' -Namespace $namespace

    Write-Log "[LoggingRestore] Restore completed" -Console
}
catch {
    Fail "Restore of addon 'logging' failed: $($_.Exception.Message)"
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
