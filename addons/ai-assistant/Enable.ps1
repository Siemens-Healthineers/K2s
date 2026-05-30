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
$aiModule           = "$PSScriptRoot\ai-assistant.module.psm1"
Import-Module $clusterModule, $infraModule, $addonsModule, $aiModule
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
# -- Check ingress prerequisite
$ingressEnabled = (Test-IsAddonEnabled -Addon ([pscustomobject]@{Name = 'ingress'; Implementation = 'nginx' })) -or
    (Test-IsAddonEnabled -Addon ([pscustomobject]@{Name = 'ingress'; Implementation = 'traefik' })) -or
    (Test-IsAddonEnabled -Addon ([pscustomobject]@{Name = 'ingress'; Implementation = 'nginx-gw' }))
if (-not $ingressEnabled) {
    $errMsg = "Addon 'ingress' is not enabled. The AI Assistant requires an ingress controller for external access to the Kagent UI.`n" +
        "Please enable an ingress addon first:`n" +
        "  k2s addons enable ingress nginx`n" +
        'Alternatively, you can use port-forwarding after enabling (without ingress):`n' +
        '  kubectl port-forward svc/kagent-ui -n kagent 8080:8080'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}
# -- Deploy Ollama (only for ollama provider)
if ($Provider -eq 'ollama') {
    Write-Log '[AI-Assistant] Configuring Ollama on Windows host (GPU-accelerated)...' -Console

    # Validate Ollama is installed before proceeding
    try {
        $null = Get-OllamaExePath
    }
    catch {
        $errMsg = "[AI-Assistant] Ollama is not installed on this machine.`n" +
            "The 'ollama' provider requires Ollama to be installed on the Windows host.`n`n" +
            "To install Ollama:`n" +
            "  1. Download from https://ollama.com/download/windows`n" +
            "  2. Run the installer`n" +
            "  3. Verify installation: ollama --version`n`n" +
            'Then re-run: k2s addons enable ai-assistant --provider ollama'
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }

    # Install/start as a resilient Windows service
    Install-OllamaWindowsService

    # Configure firewall for K8s subnet access
    Set-OllamaFirewallRule

    # Wait for Ollama API to be ready
    $ollamaReady = Wait-ForOllamaReady -TimeoutSeconds 60
    if (-not $ollamaReady) {
        $errMsg = '[AI-Assistant] Ollama is not responding on localhost:11434 after service start.'
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }

    # Pull the model
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

    # Remove legacy K8s Ollama deployment if still present
    (Invoke-Kubectl -Params 'delete', 'deployment', 'ollama', '-n', 'ai-assistant', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'service', 'ollama', '-n', 'ai-assistant', '--ignore-not-found').Output | Write-Log
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
$kagentReady = Wait-ForKagentDependency -Label 'app.kubernetes.io/component=controller,app.kubernetes.io/name=kagent' -TimeoutSeconds 300 -ComponentName 'kagent-controller'
if (-not $kagentReady) {
    # Controller not ready — might be crash-looping waiting for PostgreSQL.
    # Attempt a rollout restart to trigger reconciliation once deps are up.
    Write-Log '[AI-Assistant] Controller not ready yet — attempting restart to clear crash-loop...' -Console
    (Invoke-Kubectl -Params 'rollout', 'restart', 'deployment/kagent-controller', '-n', 'kagent').Output | Write-Log
    $kagentReady = Wait-ForKagentDependency -Label 'app.kubernetes.io/component=controller,app.kubernetes.io/name=kagent' -TimeoutSeconds 180 -ComponentName 'kagent-controller'
}
if (-not $kagentReady) {
    $errMsg = '[AI-Assistant] Kagent controller did not become ready within timeout. Check: kubectl get pods -n kagent; kubectl logs -n kagent -l app.kubernetes.io/name=kagent'
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
        # Pin model in memory to prevent cold-start latency
        Set-OllamaKeepAlive -Model $Model -KeepAlive '30m'
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
# -- Wait for agent pod and reconcile controller
# The kagent-controller starts reconciling immediately on deploy but the agent and
# k2s-tools pods may not be ready yet, causing stale connection-refused errors.
# Waiting for the agent deployment then restarting the controller eliminates this race.
Write-Log '[AI-Assistant] Waiting for agent deployment to be created and ready...' -Console
$agentDeployName = if ($Provider -eq 'copilot') { 'copilot-cli' } else { 'k2s-assistant' }
$agentReady = $false
$deadline = (Get-Date).AddSeconds(180)
while ((Get-Date) -lt $deadline) {
    $waitResult = Invoke-Kubectl -Params 'wait', '--for=condition=Available', `
        "deployment/$agentDeployName", '-n', 'kagent', '--timeout=10s'
    if ($waitResult.Success) {
        $agentReady = $true
        break
    }
    Start-Sleep -Seconds 5
}
if ($agentReady) {
    Write-Log '[AI-Assistant] Agent deployment ready. Restarting controller for clean reconciliation...' -Console
    (Invoke-Kubectl -Params 'rollout', 'restart', 'deployment/kagent-controller', '-n', 'kagent').Output | Write-Log
    $null = Invoke-Kubectl -Params 'rollout', 'status', 'deployment/kagent-controller', '-n', 'kagent', '--timeout=90s'
    Write-Log '[AI-Assistant] Controller reconciled.' -Console
}
else {
    Write-Log '[AI-Assistant] Warning: Agent deployment did not become ready in 180s. The UI may show errors until reconciliation completes.' -Console
    Write-Log "[AI-Assistant] Check: kubectl get deploy $agentDeployName -n kagent" -Console
}
# -- Persist to setup.json
Add-AddonToSetupJson -Addon ([pscustomobject]@{Name = 'ai-assistant' })
Write-Log '[AI-Assistant] AI Assistant addon enabled successfully.' -Console
Write-AiAssistantUsageForUser -Provider $Provider -Model $Model
if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
