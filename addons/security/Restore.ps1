# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Restores security addon state.

.DESCRIPTION
Restores the following security addon artifacts after the addon has been
re-enabled by the CLI (via EnableForRestore.ps1):
- CA root certificate and key (replaces auto-generated Secret, triggers cert-manager reconcile)
- Keycloak PostgreSQL database (drops and restores from pg_dump)
- Enhanced security marker file

.PARAMETER BackupDir
Directory containing backup.json and referenced backup files.

.EXAMPLE
powershell <installation folder>\addons\security\Restore.ps1 -BackupDir C:\Temp\security-restore
#>
Param(
    [parameter(Mandatory = $true, HelpMessage = 'Directory containing backup.json and referenced files')]
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
$securityModule = "$PSScriptRoot\security.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule, $securityModule

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

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    Fail $systemError.Message 'system-not-available'
    return
}

$manifestPath = Join-Path $BackupDir 'backup.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    Fail "backup.json not found in '$BackupDir'" 'addon-restore-failed'
    return
}

$manifest = Get-Content -Raw -Path $manifestPath | ConvertFrom-Json

Write-Log "[SecurityRestore] Restoring addon 'security' from '$BackupDir'" -Console

if ($null -ne $manifest.addon -and "$($manifest.addon)" -ne 'security') {
    Write-Log "[SecurityRestore] Warning: backup.json addon is '$($manifest.addon)' (expected 'security')." -Console
}

# ── 1. Restore CA root Secret ──────────────────────────────────────────────

$caSecretFile = Join-Path $BackupDir 'ca-issuer-root-secret.yaml'
if (Test-Path -LiteralPath $caSecretFile) {
    Write-Log '[SecurityRestore] Restoring CA root certificate Secret' -Console

    # Replace the auto-generated Secret with the backed-up one to preserve the trust chain.
    # Use kubectl apply with --force to replace the existing Secret.
    $applyResult = Invoke-Kubectl -Params 'apply', '--force', '-f', $caSecretFile
    if ($applyResult.Success) {
        Write-Log '[SecurityRestore] CA root Secret restored successfully' -Console

        # Trigger cert-manager to reconcile by restarting its pods.
        # This ensures cert-manager picks up the restored CA key and re-issues
        # derived certificates (ingress TLS, linkerd trust anchors) from it.
        Write-Log '[SecurityRestore] Restarting cert-manager to reconcile with restored CA' -Console
        $restartResult = Invoke-Kubectl -Params 'rollout', 'restart', 'deployment', '-n', 'cert-manager'
        if ($restartResult.Success) {
            # Wait for cert-manager to become ready again
            $waitResult = Invoke-Kubectl -Params 'rollout', 'status', 'deployment', '-n', 'cert-manager', '--timeout=120s'
            if ($waitResult.Success) {
                Write-Log '[SecurityRestore] cert-manager restarted and ready' -Console
            }
            else {
                Write-Log "[SecurityRestore] Warning: cert-manager rollout did not complete within timeout: $($waitResult.Output)" -Console
            }
        }
        else {
            Write-Log "[SecurityRestore] Warning: Failed to restart cert-manager: $($restartResult.Output)" -Console
        }
    }
    else {
        Write-Log "[SecurityRestore] Warning: Failed to restore CA root Secret: $($applyResult.Output)" -Console
    }
}
else {
    Write-Log '[SecurityRestore] No CA root Secret backup found; new CA was generated during re-enable. TLS trust chain has been reset.' -Console
}

# ── 2. Restore Keycloak PostgreSQL database ────────────────────────────────

$pgDumpFile = Join-Path $BackupDir 'keycloak-db.sql'
if (Test-Path -LiteralPath $pgDumpFile) {
    Write-Log '[SecurityRestore] Restoring Keycloak PostgreSQL database' -Console

    # Verify PostgreSQL pod is ready
    $pgReady = Invoke-Kubectl -Params 'wait', '--timeout=120s', '--for=condition=Ready', '-n', 'security', '-l', 'app=postgresql', 'pod'
    if (-not $pgReady.Success) {
        Write-Log "[SecurityRestore] Warning: PostgreSQL pod not ready, skipping database restore: $($pgReady.Output)" -Console
    }
    else {
        # Drop and recreate the keycloak database, then restore from dump.
        # This ensures a clean restore without conflicts from the default import.

        # Step 1: Stop Keycloak to release DB connections
        Write-Log '[SecurityRestore] Scaling down Keycloak to release database connections' -Console
        $scaleDown = Invoke-Kubectl -Params 'scale', 'deployment/keycloak', '-n', 'security', '--replicas=0'
        if ($scaleDown.Success) {
            # Wait for Keycloak pod to terminate
            Start-Sleep -Seconds 5
            $waitTerminate = Invoke-Kubectl -Params 'wait', '--for=delete', '-n', 'security', '-l', 'app=keycloak', 'pod', '--timeout=60s'
            if (-not $waitTerminate.Success) {
                Write-Log "[SecurityRestore] Warning: Keycloak pod did not terminate cleanly, proceeding anyway" -Console
            }
        }

        # Step 2: Drop and recreate database
        Write-Log '[SecurityRestore] Dropping and recreating keycloak database' -Console
        $dropResult = Invoke-Kubectl -Params 'exec', 'deployment/postgresql', '-n', 'security', '--', 'psql', '-U', 'admin', '-d', 'postgres', '-c', 'DROP DATABASE IF EXISTS keycloak;'
        if ($dropResult.Success) {
            $createResult = Invoke-Kubectl -Params 'exec', 'deployment/postgresql', '-n', 'security', '--', 'psql', '-U', 'admin', '-d', 'postgres', '-c', 'CREATE DATABASE keycloak OWNER admin;'
            if (-not $createResult.Success) {
                Write-Log "[SecurityRestore] Warning: Failed to create database: $($createResult.Output)" -Console
            }
        }
        else {
            Write-Log "[SecurityRestore] Warning: Failed to drop database: $($dropResult.Output)" -Console
        }

        # Step 3: Import the dump via kubectl exec with stdin
        Write-Log '[SecurityRestore] Importing database dump' -Console
        $kubeToolsPath = Get-KubeToolsPath
        $importOutput = Get-Content -Raw -Path $pgDumpFile | & "$kubeToolsPath\kubectl.exe" exec -i deployment/postgresql -n security -- psql -U admin -d keycloak 2>&1
        $importExitCode = $LASTEXITCODE
        if ($importExitCode -eq 0) {
            Write-Log '[SecurityRestore] Keycloak database restored successfully' -Console
        }
        else {
            # pg_restore/psql may emit warnings for existing objects; treat non-zero as warning
            Write-Log "[SecurityRestore] Database import completed with exit code $importExitCode (warnings may be expected)" -Console
            "$importOutput" | Write-Log
        }

        # Step 4: Scale Keycloak back up
        Write-Log '[SecurityRestore] Scaling Keycloak back up' -Console
        $scaleUp = Invoke-Kubectl -Params 'scale', 'deployment/keycloak', '-n', 'security', '--replicas=1'
        if ($scaleUp.Success) {
            $kcReady = Invoke-Kubectl -Params 'wait', '--timeout=180s', '--for=condition=Ready', '-n', 'security', '-l', 'app=keycloak', 'pod'
            if ($kcReady.Success) {
                Write-Log '[SecurityRestore] Keycloak is ready with restored database' -Console
            }
            else {
                Write-Log "[SecurityRestore] Warning: Keycloak did not become ready: $($kcReady.Output)" -Console
            }
        }
        else {
            Write-Log "[SecurityRestore] Warning: Failed to scale Keycloak back up: $($scaleUp.Output)" -Console
        }
    }
}
else {
    Write-Log '[SecurityRestore] No Keycloak database dump found; default realm/users will be used' -Console
}

# ── 3. Restore enhanced security marker ────────────────────────────────────

$markerFile = Join-Path $BackupDir 'enhancedsecurity.json'
if (Test-Path -LiteralPath $markerFile) {
    Write-Log '[SecurityRestore] Restoring enhanced security marker file' -Console
    $markerDest = Get-EnhancedSecurityFileLocation
    Copy-Item -Path $markerFile -Destination $markerDest -Force
    Write-Log '[SecurityRestore] Enhanced security marker restored' -Console
}

# ── 4. Summary ─────────────────────────────────────────────────────────────

Write-Log '[SecurityRestore] Restore completed' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
