# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Re-syncs the AI Assistant addon: re-applies Kagent manifests, re-wires proxy,
and re-injects the Headlamp plugin. Typically needed after a full cluster
reinstall or after a Headlamp upgrade.

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

# ── Clean up legacy agent resources (migration from old version) ───────────────
Remove-LegacyAgentResources

# ── Re-apply Kagent framework ─────────────────────────────────────────────────
Write-Log '[AI-Assistant] Re-applying Kagent framework manifests...' -Console
try {
    Install-KagentFramework
}
catch {
    $errMsg = "[AI-Assistant] Warning: Failed to re-apply Kagent framework: $($_.Exception.Message)"
    Write-Log $errMsg -Console
}

# ── Wait for Kagent controller ────────────────────────────────────────────────
$kagentReady = Wait-ForKagentAvailable -TimeoutSeconds 120
if (-not $kagentReady) {
    Write-Log '[AI-Assistant] Warning: Kagent controller not ready after 120s. Agent may be unavailable.' -Console
}

# ── Detect and re-apply active agent ──────────────────────────────────────────
# Check which agent CR exists to determine the active provider
$copilotAgent = (Invoke-Kubectl -Params 'get', 'agent', 'copilot-cli',
    '-n', 'kagent', '--ignore-not-found', '-o', 'name').Output
$ollamaAgent = (Invoke-Kubectl -Params 'get', 'agent', 'k2s-assistant',
    '-n', 'kagent', '--ignore-not-found', '-o', 'name').Output

if (-not [string]::IsNullOrWhiteSpace($copilotAgent)) {
    Write-Log '[AI-Assistant] Re-applying Copilot CLI agent...' -Console
    try {
        Install-CopilotAgent
    }
    catch {
        Write-Log "[AI-Assistant] Warning: Failed to re-apply Copilot agent: $($_.Exception.Message)" -Console
    }
}

if (-not [string]::IsNullOrWhiteSpace($ollamaAgent)) {
    # Detect current model from the ModelConfig
    $modelConfigJson = (Invoke-Kubectl -Params 'get', 'modelconfig', 'ollama-model-config',
        '-n', 'kagent', '-o', 'json', '--ignore-not-found').Output
    $currentModel = 'qwen2.5:7b'
    if ($modelConfigJson) {
        try {
            $mcObj = ($modelConfigJson -join '') | ConvertFrom-Json
            if ($mcObj.spec.model) {
                $currentModel = $mcObj.spec.model
            }
        }
        catch {
            Write-Log "[AI-Assistant] Warning: Could not parse ModelConfig JSON: $($_.Exception.Message)" -Console
        }
    }
    Write-Log "[AI-Assistant] Re-applying Ollama agent with model: $currentModel..." -Console
    try {
        Install-OllamaAgent -Model $currentModel
    }
    catch {
        Write-Log "[AI-Assistant] Warning: Failed to re-apply Ollama agent: $($_.Exception.Message)" -Console
    }
}

# If no agent found, the user may need to re-enable
if ([string]::IsNullOrWhiteSpace($copilotAgent) -and [string]::IsNullOrWhiteSpace($ollamaAgent)) {
    Write-Log '[AI-Assistant] No active agent found. Consider re-enabling: k2s addons disable ai-assistant; k2s addons enable ai-assistant' -Console
}

# ── Re-wire proxy service ─────────────────────────────────────────────────────
Write-Log '[AI-Assistant] Re-wiring Kagent proxy service...' -Console
try {
    Set-KagentProxyService
}
catch {
    $errMsg = "[AI-Assistant] Failed to re-wire proxy service: $($_.Exception.Message)"
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
