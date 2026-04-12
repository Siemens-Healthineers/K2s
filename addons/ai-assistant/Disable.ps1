# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Disables the AI Assistant addon for K2s.

.EXAMPLE
k2s addons disable ai-assistant
k2s addons disable ai-assistant --keep-model-data
#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Preserve the Ollama model PVC so pulled models survive a re-enable')]
    [switch] $KeepModelData = $false,
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

Write-Log '[AI-Assistant] Checking cluster status' -Console

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }
    Write-Log $systemError.Message -Error
    exit 1
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject]@{Name = 'ai-assistant'})) -ne $true) {
    $errMsg = "Addon 'ai-assistant' is already disabled, nothing to do."
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyDisabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

# ── Remove from setup.json first so Sync-HeadlampPlugins sees it as disabled ─
Remove-AddonFromSetupJson -Addon ([pscustomobject]@{Name = 'ai-assistant' })

# ── Remove plugin from Headlamp ───────────────────────────────────────────────
Write-Log '[AI-Assistant] Removing AI Assistant plugin from Headlamp...' -Console
Sync-HeadlampPlugins

# ── Tear down Kubernetes workloads ────────────────────────────────────────────
Write-Log '[AI-Assistant] Removing AI Assistant workloads...' -Console
try {
    Remove-AiAssistantResources -KeepModelData:$KeepModelData
}
catch {
    Write-Log "[AI-Assistant] Warning during resource removal: $($_.Exception.Message)" -Console
}

Write-Log '[AI-Assistant] AI Assistant addon disabled.' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}

