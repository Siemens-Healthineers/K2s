# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Enables the AI Assistant addon for K2s.
.DESCRIPTION
Deploys the Kagent AI agent framework with a configurable backend provider:
  - 'copilot' (default): Kagent + Copilot CLI BYO agent (connected, requires GitHub PAT)
  - 'ollama':            Kagent + Ollama local LLM (offline/air-gapped, no external deps)
Both providers deploy the Kagent framework as the agent orchestration layer.
The Ollama provider additionally deploys a local LLM runtime and pulls a model.
.EXAMPLE
k2s addons enable ai-assistant
k2s addons enable ai-assistant --provider copilot --github-token ghp_xxx
k2s addons enable ai-assistant --provider ollama --model mistral
k2s addons enable ai-assistant --provider ollama --model phi3 --gpu
#>
[CmdletBinding(SupportsShouldProcess = $true)]
Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Agent provider: copilot (connected) or ollama (offline)')]
    [ValidateSet('copilot', 'ollama')]
    [string] $Provider = 'copilot',
    [parameter(Mandatory = $false, HelpMessage = 'Ollama model to pull and use (only for ollama provider)')]
    [string] $Model = 'qwen2.5:7b',
    [parameter(Mandatory = $false, HelpMessage = 'GitHub PAT with Copilot Requests permission (only for copilot provider)')]
    [string] $GithubToken = '',
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
# -- Override from $Config if supplied
if ($Config) {
    if ($Config.PSObject.Properties['Provider'])    { $Provider    = $Config.Provider }
    if ($Config.PSObject.Properties['Model'])       { $Model       = $Config.Model }
    if ($Config.PSObject.Properties['GithubToken']) { $GithubToken = $Config.GithubToken }
    if ($Config.PSObject.Properties['Gpu'])         { $Gpu         = $Config.Gpu }
}
Write-Log "[AI-Assistant] Provider: $Provider" -Console
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
# -- Prerequisite: dashboard addon must be enabled
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
# -- Already enabled?
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
# -- Clean up legacy HolmesGPT resources from previous versions
Remove-LegacyHolmesResources
# -- Deploy Ollama (only for ollama provider)
if ($Provider -eq 'ollama') {
    Write-Log '[AI-Assistant] Deploying Ollama (local LLM runtime)...' -Console
    New-OllamaDataDirectory
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
    # Pull the model (waits for pod ready first)
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
}
# -- Deploy Kagent Framework
Write-Log '[AI-Assistant] Deploying Kagent framework...' -Console
try {
    Install-KagentFramework
}
catch {
    $errMsg = "Failed to deploy Kagent framework: $($_.Exception.Message)"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}
Write-Log '[AI-Assistant] Waiting for Kagent controller to be ready...' -Console
$kagentReady = Wait-ForKagentAvailable
if (-not $kagentReady) {
    $errMsg = '[AI-Assistant] Kagent controller did not become ready within 300s. Check: kubectl get pods -n kagent'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}
# -- Deploy provider-specific agent
try {
    if ($Provider -eq 'copilot') {
        Install-CopilotAgent -GithubToken $GithubToken
    }
    else {
        Install-OllamaAgent -Model $Model
    }
}
catch {
    $errMsg = "Failed to deploy $Provider agent: $($_.Exception.Message)"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}
# -- Wire proxy service for Headlamp
try {
    Set-KagentProxyService
}
catch {
    $errMsg = "Failed to configure Kagent proxy service: $($_.Exception.Message)"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}
# -- Persist to setup.json BEFORE plugin sync
Add-AddonToSetupJson -Addon ([pscustomobject]@{Name = 'ai-assistant' })
# -- Inject AI Assistant plugin into Headlamp
Write-Log '[AI-Assistant] Injecting AI Assistant plugin into Headlamp...' -Console
Sync-HeadlampPlugins
Write-Log '[AI-Assistant] AI Assistant addon enabled successfully.' -Console
Write-AiAssistantUsageForUser -Provider $Provider -Model $Model
Write-BrowserWarningForUser
if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
