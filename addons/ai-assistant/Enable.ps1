# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Enables the AI Assistant addon for K2s.

.DESCRIPTION
Deploys Ollama (local LLM runtime) and HolmesGPT (Kubernetes AI agent) into the
ai-assistant namespace, pulls the requested model, and injects the AI Assistant
plugin into the Headlamp dashboard.

.EXAMPLE
k2s addons enable ai-assistant
k2s addons enable ai-assistant --model mistral
k2s addons enable ai-assistant --model phi3 --gpu
#>

[CmdletBinding(SupportsShouldProcess = $true)]
Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Ollama model to pull and use (e.g. qwen2.5:7b, mistral, phi3)')]
    [string] $Model = 'qwen2.5:7b',
    [parameter(Mandatory = $false, HelpMessage = 'Enable GPU acceleration for Ollama (requires GPU node label)')]
    [switch] $Gpu = $false,
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceding parameters')]
    [pscustomobject] $Config,
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

# ── Override from $Config if supplied ────────────────────────────────────────
if ($Config) {
    if ($Config.PSObject.Properties['Model'])  { $Model = $Config.Model }
    if ($Config.PSObject.Properties['Gpu'])    { $Gpu   = $Config.Gpu   }
}

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

$setupInfo = Get-SetupInfo
if ($setupInfo.Name -ne 'k2s') {
    $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) `
        -Message "Addon 'ai-assistant' can only be enabled for 'k2s' setup type."
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
}

# ── Prerequisite: dashboard addon must be enabled ────────────────────────────
if ((Test-IsAddonEnabled -Addon ([pscustomobject]@{Name = 'dashboard'})) -ne $true) {
    $errMsg = "Addon 'ai-assistant' requires the 'dashboard' addon to be enabled first.`n" +
              "Run: k2s addons enable dashboard"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

# ── Already enabled? ─────────────────────────────────────────────────────────
if ((Test-IsAddonEnabled -Addon ([pscustomobject]@{Name = 'ai-assistant'})) -eq $true) {
    $errMsg = "Addon 'ai-assistant' is already enabled, nothing to do."
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

# ── Deploy Ollama ─────────────────────────────────────────────────────────────
Write-Log '[AI-Assistant] Deploying Ollama (local LLM runtime)...' -Console

# Ensure the backing directory exists on kubemaster before applying the PV/PVC
New-OllamaDataDirectory

# Create the ZScaler CA ConfigMap so the Ollama init-container can trust the corporate proxy
New-ZscalerCaConfigMap

$ollamaResult = Invoke-Kubectl -Params 'apply', '-f', (Get-OllamaManifestPath)
$ollamaResult.Output | Write-Log
if (-not $ollamaResult.Success) {
    $errMsg = '[AI-Assistant] Failed to apply Ollama manifests.'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

# Optional: patch GPU node-selector onto the Ollama deployment
if ($Gpu) {
    Write-Log '[AI-Assistant] Patching Ollama deployment for GPU acceleration...' -Console
    $gpuPatch = '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/os":"linux","gpu":"true"},"containers":[{"name":"ollama","resources":{"limits":{"nvidia.com/gpu":"1"}}}]}}}}'
    (Invoke-Kubectl -Params 'patch', 'deployment', 'ollama', '-n', 'ai-assistant', '-p', $gpuPatch).Output | Write-Log
}

# ── Pull the model (waits for pod ready first) ────────────────────────────────
try {
    Invoke-OllamaModelPull -Model $Model
}
catch {
    $errMsg = "Failed to pull Ollama model '$Model': $($_.Exception.Message)"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

# ── Deploy HolmesGPT ──────────────────────────────────────────────────────────
Write-Log '[AI-Assistant] Deploying HolmesGPT agent...' -Console

try {
    Set-HolmesModelConfig -Model $Model
}
catch {
    $errMsg = "Failed to deploy HolmesGPT: $($_.Exception.Message)"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

Write-Log '[AI-Assistant] Waiting for HolmesGPT to be ready...' -Console
$holmesReady = Wait-ForHolmesAvailable
if (-not $holmesReady) {
    $errMsg = '[AI-Assistant] HolmesGPT pod did not become ready within 120s. Check: kubectl describe pods -n ai-assistant -l app=holmesgpt'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

# ── Wire cross-namespace proxy Endpoints ──────────────────────────────────────
# Populates the selectorless Service in 'default' namespace with the ClusterIP
# of the real HolmesGPT service so the Headlamp plugin's K8s API proxy path works.
try {
    Set-HolmesProxyEndpoints
}
catch {
    $errMsg = "Failed to configure HolmesGPT proxy endpoints: $($_.Exception.Message)"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

# ── Inject AI Assistant plugin into Headlamp ──────────────────────────────────
Write-Log '[AI-Assistant] Injecting AI Assistant plugin into Headlamp...' -Console
Sync-HeadlampPlugins

# ── Persist to setup.json ─────────────────────────────────────────────────────
Add-AddonToSetupJson -Addon ([pscustomobject]@{Name = 'ai-assistant' })

Write-Log '[AI-Assistant] AI Assistant addon enabled successfully.' -Console

Write-AiAssistantUsageForUser -Model $Model
Write-BrowserWarningForUser

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}

