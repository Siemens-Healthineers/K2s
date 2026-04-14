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
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
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
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }
    Write-Log $systemError.Message -Error
    exit 1
}

# ── Pre-flight: addon must be enabled ─────────────────────────────────────────
if ((Test-IsAddonEnabled -Addon ([pscustomobject]@{Name = 'ai-assistant'})) -ne $true) {
    $errMsg = "[AI-Assistant] Addon 'ai-assistant' is not enabled. Run: k2s addons enable ai-assistant"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

# ── Pre-flight: HolmesGPT service must exist in ai-assistant namespace ────────
$holmesSvc = (Invoke-Kubectl -Params 'get', 'svc', 'holmesgpt-holmes',
    '-n', 'ai-assistant', '--ignore-not-found', '-o', 'name').Output

if ([string]::IsNullOrWhiteSpace($holmesSvc)) {
    $errMsg = '[AI-Assistant] HolmesGPT service not found in ai-assistant namespace. Check: kubectl get pods -n ai-assistant -l app=holmesgpt'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    Write-Log '[AI-Assistant] If the service is permanently missing, re-enable the addon: k2s addons disable ai-assistant; k2s addons enable ai-assistant' -Console
    exit 1
}

# ── Re-apply HolmesGPT manifest (updates prompt-overrides ConfigMap) ──────────
Write-Log '[AI-Assistant] Re-applying HolmesGPT manifest to refresh prompt ConfigMaps...' -Console

# Snapshot the live MODEL value BEFORE applying. Use ConvertFrom-Json to avoid PowerShell
# stripping the double-quotes required by the jsonpath filter expression.
$liveModelResult = Invoke-Kubectl -Params 'get', 'deployment', 'holmesgpt-holmes',
    '-n', 'ai-assistant', '-o', 'json'
$liveModel = ''
if ($liveModelResult.Success -and $liveModelResult.Output) {
    try {
        $deployJson = ($liveModelResult.Output -join '') | ConvertFrom-Json
        $modelEnv = $deployJson.spec.template.spec.containers[0].env |
            Where-Object { $_.name -eq 'MODEL' } |
            Select-Object -First 1
        $liveModel = if ($modelEnv) { $modelEnv.value } else { '' }
    }
    catch {
        Write-Log "[AI-Assistant] Warning: could not parse deployment JSON to read live MODEL: $($_.Exception.Message)" -Console
    }
}

# Strip the "openai/" LiteLLM prefix to get the bare Ollama model name for Set-HolmesModelConfig.
# If the live value is missing or still the placeholder, fall back to qwen2.5:7b.
$bareModel = $liveModel -replace '^openai/', ''
if ([string]::IsNullOrWhiteSpace($bareModel) -or $bareModel -eq 'MODEL_PLACEHOLDER') {
    $bareModel = 'qwen2.5:7b'
}
Write-Log "[AI-Assistant] Using model for re-apply: $bareModel (live was: $liveModel)" -Console

try {
    Set-HolmesModelConfig -Model $bareModel
    # Restart HolmesGPT pod so it picks up any updated ConfigMap data
    (Invoke-Kubectl -Params 'rollout', 'restart', 'deployment/holmesgpt-holmes', '-n', 'ai-assistant').Output | Write-Log
    Write-Log '[AI-Assistant] HolmesGPT deployment restarted to apply updated ConfigMaps.' -Console
}
catch {
    Write-Log "[AI-Assistant] Warning: Failed to re-apply HolmesGPT manifest: $($_.Exception.Message). Prompt config may be outdated." -Console
}

# ── Re-wire proxy Endpoints ───────────────────────────────────────────────────
Write-Log '[AI-Assistant] Re-wiring HolmesGPT proxy Endpoints...' -Console
try {
    Set-HolmesProxyEndpoints
}
catch {
    $errMsg = "[AI-Assistant] Failed to re-wire proxy Endpoints: $($_.Exception.Message)"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

# ── Re-sync Headlamp plugin ───────────────────────────────────────────────────
Write-Log '[AI-Assistant] Re-syncing Headlamp plugin injection...' -Console
Sync-HeadlampPlugins

Write-Log '[AI-Assistant] Update complete. The AI Assistant should now be reachable in Headlamp.' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
