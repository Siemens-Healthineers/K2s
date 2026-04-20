# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Import-Module "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k8s-api/k8s-api.module.psm1"

# ── Ollama ────────────────────────────────────────────────────────────────────
$ollamaReady = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available',
    '-n', 'ai-assistant', 'deployment/ollama').Success

$isOllamaRunningProp = @{
    Name  = 'IsOllamaRunning'
    Value = $ollamaReady
    Okay  = $ollamaReady
}
$isOllamaRunningProp.Message = if ($ollamaReady) {
    'Ollama LLM runtime is running'
} else {
    "Ollama is not running. Check: kubectl get pods -n ai-assistant -l app=ollama"
}

# ── HolmesGPT ─────────────────────────────────────────────────────────────────
$holmesReady = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available',
    '-n', 'ai-assistant', 'deployment/holmesgpt-holmes').Success

$isHolmesRunningProp = @{
    Name  = 'IsHolmesGptRunning'
    Value = $holmesReady
    Okay  = $holmesReady
}
$isHolmesRunningProp.Message = if ($holmesReady) {
    'HolmesGPT agent is running'
} else {
    "HolmesGPT is not running. Check: kubectl get pods -n ai-assistant -l app=holmesgpt"
}

# ── Proxy pod (default namespace) ─────────────────────────────────────────────
# K8s 1.35 apiserver proxy requires a selector-based Service backed by real pods.
# We deploy a Python smart-proxy pod in 'default' that injects the strict system
# prompt and forwards to HolmesGPT in 'ai-assistant'. Check that the deployment
# is available.
$proxyExists = -not [string]::IsNullOrWhiteSpace(
    (Invoke-Kubectl -Params 'get', 'deployment', 'holmesgpt-proxy', '-n', 'default', '--ignore-not-found', '-o', 'name').Output
)
$proxyReady = $proxyExists -and (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available',
    '-n', 'default', 'deployment/holmesgpt-proxy').Success
$proxyWired = $proxyReady

$isProxyWiredProp = @{
    Name  = 'IsHolmesProxyWired'
    Value = $proxyWired
    Okay  = $proxyWired
}
$isProxyWiredProp.Message = if ($proxyWired) {
    'HolmesGPT smart proxy is running in default namespace (strict mode active)'
} else {
    "HolmesGPT proxy pod missing in default namespace. Fix: k2s addons update ai-assistant"
}

# ── SSE Ingress (ai-assistant namespace) ──────────────────────────────────────
# The holmesgpt-sse-direct ingress bypasses the K8s apiserver proxy to enable
# SSE streaming. Check that the ingress exists and has an assigned address.
$sseIngressAddr = (Invoke-Kubectl -Params 'get', 'ingress', 'holmesgpt-sse-direct',
    '-n', 'ai-assistant', '-o', 'jsonpath={.status.loadBalancer.ingress[0].ip}',
    '--ignore-not-found').Output
$sseIngressReady = -not [string]::IsNullOrWhiteSpace($sseIngressAddr)

$isSseIngressProp = @{
    Name  = 'IsSseIngressReady'
    Value = $sseIngressReady
    Okay  = $sseIngressReady
}
$isSseIngressProp.Message = if ($sseIngressReady) {
    "SSE direct-route ingress is active (address: $sseIngressAddr)"
} else {
    "SSE direct-route ingress missing or not ready. Fix: k2s addons update ai-assistant"
}

# ── Plugin injection ──────────────────────────────────────────────────────────
$initContainerRaw = (Invoke-Kubectl -Params 'get', 'deployment', 'headlamp', '-n', 'dashboard',
    '-o', 'jsonpath={.spec.template.spec.initContainers[*].name}', '--ignore-not-found').Output

# Explicit boolean cast – -match returns an array/bool depending on input type
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

return , @($isOllamaRunningProp, $isHolmesRunningProp, $isProxyWiredProp, $isSseIngressProp, $isPluginInjectedProp)
