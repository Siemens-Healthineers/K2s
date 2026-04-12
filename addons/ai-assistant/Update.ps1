# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Re-syncs the AI Assistant plugin into Headlamp and re-wires proxy Endpoints.
Typically needed after a full cluster reinstall (when service ClusterIPs change)
or after a Headlamp upgrade. Pod/deployment restarts do NOT require re-wiring,
because Endpoints now point to the stable ClusterIP of the Holmes service.

.EXAMPLE
k2s addons update ai-assistant
#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)

$clusterModule      = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$infraModule        = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$addonsModule       = "$PSScriptRoot\..\addons.module.psm1"
$dashboardModule    = "$PSScriptRoot\..\dashboard\dashboard.module.psm1"
$aiModule           = "$PSScriptRoot\ai-assistant.module.psm1"

Import-Module $clusterModule, $infraModule, $addonsModule, $dashboardModule, $aiModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log '[AI-Assistant] Running Update...' -Console

# ── Pre-flight: cluster must be available ─────────────────────────────────────
$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    Write-Log $systemError.Message -Error
    exit 1
}

# ── Pre-flight: addon must be enabled ─────────────────────────────────────────
if ((Test-IsAddonEnabled -Addon ([pscustomobject]@{Name = 'ai-assistant'})) -ne $true) {
    Write-Log "[AI-Assistant] Addon 'ai-assistant' is not enabled. Run: k2s addons enable ai-assistant" -Error
    exit 1
}

# ── Pre-flight: HolmesGPT service must exist in ai-assistant namespace ────────
$holmesSvc = (Invoke-Kubectl -Params 'get', 'svc', 'holmesgpt-holmes',
    '-n', 'ai-assistant', '--ignore-not-found', '-o', 'name').Output

if ([string]::IsNullOrWhiteSpace($holmesSvc)) {
    Write-Log '[AI-Assistant] HolmesGPT service not found in ai-assistant namespace.' -Error
    Write-Log '[AI-Assistant] The pod may still be starting up. Check: kubectl get pods -n ai-assistant -l app=holmesgpt' -Console
    Write-Log '[AI-Assistant] If the service is permanently missing, re-enable the addon: k2s addons disable ai-assistant; k2s addons enable ai-assistant' -Console
    exit 1
}

# ── Re-wire proxy Endpoints ───────────────────────────────────────────────────
Write-Log '[AI-Assistant] Re-wiring HolmesGPT proxy Endpoints...' -Console
try {
    Set-HolmesProxyEndpoints
}
catch {
    Write-Log "[AI-Assistant] Failed to re-wire proxy Endpoints: $($_.Exception.Message)" -Error
    exit 1
}

# ── Re-sync Headlamp plugin ───────────────────────────────────────────────────
Write-Log '[AI-Assistant] Re-syncing Headlamp plugin injection...' -Console
Sync-HeadlampPlugins

Write-Log '[AI-Assistant] Update complete. The AI Assistant should now be reachable in Headlamp.' -Console
