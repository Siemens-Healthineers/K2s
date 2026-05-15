# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Import-Module "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k8s-api/k8s-api.module.psm1"

# ── Kagent Controller ─────────────────────────────────────────────────────────
$kagentControllerReady = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available',
    '-n', 'kagent', 'deployment/kagent-controller').Success

$isKagentRunningProp = @{
    Name  = 'IsKagentControllerRunning'
    Value = $kagentControllerReady
    Okay  = $kagentControllerReady
}
$isKagentRunningProp.Message = if ($kagentControllerReady) {
    'Kagent controller is running'
} else {
    "Kagent controller is not running. Check: kubectl get pods -n kagent -l app.kubernetes.io/component=controller"
}

# ── Detect active provider ────────────────────────────────────────────────────
$copilotAgentExists = -not [string]::IsNullOrWhiteSpace(
    (Invoke-Kubectl -Params 'get', 'agent', 'copilot-cli', '-n', 'kagent', '--ignore-not-found', '-o', 'name').Output
)
$ollamaAgentExists = -not [string]::IsNullOrWhiteSpace(
    (Invoke-Kubectl -Params 'get', 'agent', 'k2s-assistant', '-n', 'kagent', '--ignore-not-found', '-o', 'name').Output
)

$activeProvider = 'none'
if ($copilotAgentExists) { $activeProvider = 'copilot' }
if ($ollamaAgentExists)  { $activeProvider = 'ollama' }

$isProviderProp = @{
    Name  = 'ActiveProvider'
    Value = $activeProvider
    Okay  = ($activeProvider -ne 'none')
}
$isProviderProp.Message = if ($activeProvider -eq 'copilot') {
    'Active provider: Copilot CLI (connected mode)'
} elseif ($activeProvider -eq 'ollama') {
    'Active provider: Ollama (offline/local mode)'
} else {
    "No active agent found. Re-enable: k2s addons disable ai-assistant; k2s addons enable ai-assistant"
}

# ── Ollama (only checked if ollama provider is active) ────────────────────────
$ollamaReady = $false
if ($activeProvider -eq 'ollama') {
    $ollamaReady = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available',
        '-n', 'ai-assistant', 'deployment/ollama').Success
}

$isOllamaRunningProp = @{
    Name  = 'IsOllamaRunning'
    Value = $ollamaReady
    Okay  = ($activeProvider -ne 'ollama') -or $ollamaReady
}
$isOllamaRunningProp.Message = if ($activeProvider -ne 'ollama') {
    'Ollama not needed (copilot provider active)'
} elseif ($ollamaReady) {
    'Ollama LLM runtime is running'
} else {
    "Ollama is not running. Check: kubectl get pods -n ai-assistant -l app=ollama"
}

# ── Kagent Proxy Service (default namespace) ──────────────────────────────────
$proxyExists = -not [string]::IsNullOrWhiteSpace(
    (Invoke-Kubectl -Params 'get', 'service', 'kagent-proxy', '-n', 'default', '--ignore-not-found', '-o', 'name').Output
)

$isProxyWiredProp = @{
    Name  = 'IsKagentProxyWired'
    Value = $proxyExists
    Okay  = $proxyExists
}
$isProxyWiredProp.Message = if ($proxyExists) {
    'Kagent proxy service is wired in default namespace'
} else {
    "Kagent proxy service missing in default namespace. Fix: k2s addons update ai-assistant"
}

# ── Kagent Ingress ────────────────────────────────────────────────────────────
$ingressAddr = (Invoke-Kubectl -Params 'get', 'ingress', 'kagent-controller-ingress',
    '-n', 'kagent', '-o', 'jsonpath={.status.loadBalancer.ingress[0].ip}',
    '--ignore-not-found').Output
$ingressReady = -not [string]::IsNullOrWhiteSpace($ingressAddr)

$isIngressProp = @{
    Name  = 'IsKagentIngressReady'
    Value = $ingressReady
    Okay  = $ingressReady
}
$isIngressProp.Message = if ($ingressReady) {
    "Kagent ingress is active (address: $ingressAddr)"
} else {
    "Kagent ingress missing or not ready. Fix: k2s addons update ai-assistant"
}

# ── Plugin injection ──────────────────────────────────────────────────────────
$initContainerRaw = (Invoke-Kubectl -Params 'get', 'deployment', 'headlamp', '-n', 'dashboard',
    '-o', 'jsonpath={.spec.template.spec.initContainers[*].name}', '--ignore-not-found').Output

$pluginInjected = [bool]($initContainerRaw -match 'ai-assistant-plugin')

$isPluginInjectedProp = @{
    Name  = 'IsAiPluginInjected'
    Value = $pluginInjected
    Okay  = $pluginInjected
}
$isPluginInjectedProp.Message = if ($pluginInjected) {
    'AI Assistant plugin is injected into Headlamp'
} else {
    "AI Assistant plugin is NOT injected into Headlamp. Try: k2s addons disable ai-assistant; k2s addons enable ai-assistant"
}

return , @($isKagentRunningProp, $isProviderProp, $isOllamaRunningProp, $isProxyWiredProp, $isIngressProp, $isPluginInjectedProp)
