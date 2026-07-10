# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"
$rolloutModule = "$PSScriptRoot\rollout.module.psm1"
$dashboardModule = "$PSScriptRoot\..\..\dashboard\dashboard.module.psm1"

Import-Module $addonsModule, $rolloutModule

$addonSyncInsecureValue = $null
$addonSyncConfigExists = (Invoke-Kubectl -Params 'get', 'configmap', 'addon-sync-config', '-n', 'k2s-addon-sync', '--ignore-not-found').Output
if ((($addonSyncConfigExists -join '').Trim()).Length -gt 0) {
    $insecureGetCmd = Invoke-Kubectl -Params 'get', 'configmap', 'addon-sync-config', '-n', 'k2s-addon-sync', '-o', 'jsonpath={.data.INSECURE}'
    if ($insecureGetCmd.Success -and -not [string]::IsNullOrWhiteSpace(($insecureGetCmd.Output -join '').Trim())) {
        $addonSyncInsecureValue = ($insecureGetCmd.Output -join '').Trim()
        Write-Log "[AddonSync] Preserving existing INSECURE value '$addonSyncInsecureValue' during rollout/fluxcd update" -Console
    }
}

Update-IngressForAddon -Addon ([pscustomobject] @{Name = 'rollout'; Implementation = 'fluxcd' })

$EnhancedSecurityEnabled = Test-LinkerdServiceAvailability
if ($EnhancedSecurityEnabled) {
    Write-Log "Updating rollout addon to be part of service mesh"  
    (Invoke-Kubectl -Params 'annotate', 'namespace', 'rollout', 'linkerd.io/inject=enabled').Output | Write-Log
    (Invoke-Kubectl -Params 'annotate', 'namespace', 'rollout', 'config.linkerd.io/skip-outbound-ports=8181').Output | Write-Log
} else {
    Write-Log "Updating rollout addon to not be part of service mesh"
    (Invoke-Kubectl -Params 'annotate', 'namespace', 'rollout', 'linkerd.io/inject-').Output | Write-Log
    (Invoke-Kubectl -Params 'annotate', 'namespace', 'rollout', 'config.linkerd.io/skip-outbound-ports-').Output | Write-Log
}
(Invoke-Kubectl -Params 'rollout', 'restart', 'deployment', '-n', 'rollout').Output | Write-Log
(Invoke-Kubectl -Params 'rollout', 'status', 'deployment', '-n', 'rollout', '--timeout', '60s').Output | Write-Log

if (-not [string]::IsNullOrWhiteSpace($addonSyncInsecureValue)) {
    $insecurePatch = "{\"data\":{\"INSECURE\":\"$addonSyncInsecureValue\"}}"
    $insecurePatchCmd = Invoke-Kubectl -Params 'patch', 'configmap', 'addon-sync-config', '-n', 'k2s-addon-sync', '--type', 'merge', '-p', $insecurePatch
    $insecurePatchCmd.Output | Write-Log
    if ($insecurePatchCmd.Success) {
        Write-Log "[AddonSync] Re-applied preserved INSECURE value '$addonSyncInsecureValue' after rollout/fluxcd update" -Console
    } else {
        Write-Log '[AddonSync] Failed to re-apply preserved INSECURE value after rollout/fluxcd update' -Error
    }
}

if (Test-Path $dashboardModule) {
    Import-Module $dashboardModule -Force
    if (Get-Command Sync-HeadlampPlugins -ErrorAction SilentlyContinue) {
        Write-Log '[Dashboard][Plugin] Syncing Headlamp plugins after rollout/fluxcd update' -Console
        try {
            Sync-HeadlampPlugins
        }
        catch {
            # Plugin sync is best-effort: a failure here must not fail the primary addon operation.
            Write-Log "[Dashboard][Plugin] Headlamp plugin sync failed (rollout/fluxcd update continues): $($_.Exception.Message)" -Console
        }
    }
}

