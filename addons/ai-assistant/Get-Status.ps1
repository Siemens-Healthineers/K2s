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
    # Check Windows Ollama service/process health
    try {
        $r = curl.exe -s http://localhost:11434/api/tags --max-time 3 2>&1
        $ollamaReady = ($r -match '"models"')
    }
    catch {
        $ollamaReady = $false
    }
}

$isOllamaRunningProp = @{
    Name  = 'IsOllamaRunning'
    Value = $ollamaReady
    Okay  = ($activeProvider -ne 'ollama') -or $ollamaReady
}
$isOllamaRunningProp.Message = if ($activeProvider -ne 'ollama') {
    'Ollama not needed (copilot provider active)'
} elseif ($ollamaReady) {
    'Ollama LLM runtime is running (Windows host, GPU-accelerated)'
} else {
    "Ollama is not running on Windows host. Check: Get-Service K2sOllama"
}

# ── A2A Proxy (kagent namespace) ───────────────────────────────────────────────
$proxyReady = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available',
    'deployment/a2a-proxy', '-n', 'kagent').Success

$isProxyWiredProp = @{
    Name  = 'IsA2aProxyRunning'
    Value = $proxyReady
    Okay  = $proxyReady
}
$isProxyWiredProp.Message = if ($proxyReady) {
    'A2A proxy is running in kagent namespace'
} else {
    "A2A proxy is not running. Fix: k2s addons update ai-assistant"
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

# ── Kagent UI ──────────────────────────────────────────────────────────────────
$kagentUiReady = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available',
    '-n', 'kagent', 'deployment/kagent-ui').Success

$isKagentUiProp = @{
    Name  = 'IsKagentUiRunning'
    Value = $kagentUiReady
    Okay  = $kagentUiReady
}
$isKagentUiProp.Message = if ($kagentUiReady) {
    'Kagent UI is running (access via: https://k2s.cluster.local/agents)'
} else {
    "Kagent UI is not running. Check: kubectl get pods -n kagent -l app.kubernetes.io/component=ui"
}

return , @($isKagentRunningProp, $isProviderProp, $isOllamaRunningProp, $isProxyWiredProp, $isIngressProp, $isKagentUiProp)
