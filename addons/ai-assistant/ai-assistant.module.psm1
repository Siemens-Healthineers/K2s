# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
AI Assistant addon module — provider-abstracted backend for Headlamp AI integration.

.DESCRIPTION
Supports two agent providers:
  - 'copilot'  : Kagent + Copilot CLI BYO agent (connected, requires GitHub PAT)
  - 'ollama'   : Kagent + Ollama local model (offline/air-gapped, no external deps)

Both providers deploy the Kagent framework (controller, UI, tools, PostgreSQL)
as the agent orchestration layer. The difference is which agent backend is
registered and how the LLM is accessed.
#>

$infraModule    = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule  = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$nodeModule     = "$PSScriptRoot/../../lib/modules/k2s/k2s.node.module/k2s.node.module.psm1"
$addonsModule   = "$PSScriptRoot\..\addons.module.psm1"

Import-Module $infraModule, $clusterModule, $nodeModule, $addonsModule

# ── Path helpers ──────────────────────────────────────────────────────────────

function Get-AiAssistantManifestsDir {
    return "$PSScriptRoot\manifests"
}

function Get-OllamaManifestPath {
    return "$PSScriptRoot\manifests\ollama\ollama.yaml"
}

function Get-KagentManifestsDir {
    return "$PSScriptRoot\manifests\kagent"
}

function Get-KagentNamespacePath {
    return "$(Get-KagentManifestsDir)\namespace.yaml"
}

function Get-KagentCrdsPath {
    return "$(Get-KagentManifestsDir)\kagent-crds.yaml"
}

function Get-KagentCorePath {
    return "$(Get-KagentManifestsDir)\kagent.yaml"
}

function Get-KagentA2aProxyPath {
    return "$(Get-KagentManifestsDir)\a2a-proxy.yaml"
}

function Get-KagentMcpPreprocessorPath {
    return "$(Get-KagentManifestsDir)\mcp-preprocessor.yaml"
}

function Get-KagentToolsRbacPath {
    return "$(Get-KagentManifestsDir)\k2s-tools-rbac.yaml"
}

function Get-KagentLocalPathProvisionerPath {
    return "$(Get-KagentManifestsDir)\local-path-provisioner.yaml"
}

function Get-KagentCopilotAgentPath {
    return "$(Get-KagentManifestsDir)\copilot-cli-agent.yaml"
}

function Get-KagentOllamaAgentPath {
    return "$(Get-KagentManifestsDir)\ollama-agent.yaml"
}

function Get-KagentIngressPath {
    return "$(Get-KagentManifestsDir)\kagent-ingress.yaml"
}

# ── Kagent Framework Deployment ───────────────────────────────────────────────

<#
.SYNOPSIS
Builds the a2a-proxy and mcp-preprocessor container images on the control plane node.
These are locally-built Go binaries that need to be containerized via buildah
and loaded into CRI-O storage so Kubernetes can use them with imagePullPolicy: Never.
#>
function Build-LocalProxyImages {
    [CmdletBinding()]
    Param()

    $a2aProxyBin = "$PSScriptRoot\..\..\bin\a2a-proxy"
    $mcpPreprocessorBin = "$PSScriptRoot\..\..\bin\mcp-preprocessor"

    if (-not (Test-Path $a2aProxyBin)) {
        throw "[AI-Assistant] a2a-proxy binary not found at '$a2aProxyBin'. Run 'bgol' to build Linux binaries first."
    }
    if (-not (Test-Path $mcpPreprocessorBin)) {
        throw "[AI-Assistant] mcp-preprocessor binary not found at '$mcpPreprocessorBin'. Run 'bgol' to build Linux binaries first."
    }

    # Check if images already exist on the node
    $existingImages = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 10 -CmdToExecute 'sudo crictl images 2>/dev/null | grep -c "a2a-proxy\|mcp-preprocessor" || echo 0').Output
    if ($existingImages -match '^\s*2\s*$') {
        Write-Log '[AI-Assistant] a2a-proxy and mcp-preprocessor images already present on node — skipping build.' -Console
        return
    }

    Write-Log '[AI-Assistant] Copying proxy binaries to control plane node...' -Console
    Copy-ToControlPlaneViaSSHKey -Source $a2aProxyBin -Target '/tmp/a2a-proxy'
    Copy-ToControlPlaneViaSSHKey -Source $mcpPreprocessorBin -Target '/tmp/mcp-preprocessor'

    Write-Log '[AI-Assistant] Making binaries executable...' -Console
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 10 -CmdToExecute 'chmod +x /tmp/a2a-proxy /tmp/mcp-preprocessor').Output | Write-Log

    Write-Log '[AI-Assistant] Building a2a-proxy container image via buildah...' -Console
    $buildA2a = @(
        'sudo buildah from --name a2a-build scratch'
        'sudo buildah copy a2a-build /tmp/a2a-proxy /a2a-proxy'
        'sudo buildah config --entrypoint ''["/a2a-proxy"]'' a2a-build'
        'sudo buildah config --user 65534:65534 a2a-build'
        'sudo buildah commit a2a-build shsk2s.azurecr.io/a2a-proxy:latest'
        'sudo buildah rm a2a-build'
    ) -join ' && '
    $r = Invoke-CmdOnControlPlaneViaSSHKey -Timeout 60 -CmdToExecute $buildA2a
    $r.Output | Write-Log
    if ($r.Output -match 'error') {
        Write-Log "[AI-Assistant] Warning: a2a-proxy image build may have issues: $($r.Output)" -Console
    }

    Write-Log '[AI-Assistant] Building mcp-preprocessor container image via buildah...' -Console
    $buildMcp = @(
        'sudo buildah from --name mcp-build scratch'
        'sudo buildah copy mcp-build /tmp/mcp-preprocessor /mcp-preprocessor'
        'sudo buildah config --entrypoint ''["/mcp-preprocessor"]'' mcp-build'
        'sudo buildah config --user 65534:65534 mcp-build'
        'sudo buildah commit mcp-build shsk2s.azurecr.io/mcp-preprocessor:latest'
        'sudo buildah rm mcp-build'
    ) -join ' && '
    $r = Invoke-CmdOnControlPlaneViaSSHKey -Timeout 60 -CmdToExecute $buildMcp
    $r.Output | Write-Log
    if ($r.Output -match 'error') {
        Write-Log "[AI-Assistant] Warning: mcp-preprocessor image build may have issues: $($r.Output)" -Console
    }

    Write-Log '[AI-Assistant] Copying images to CRI-O storage...' -Console
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 30 -CmdToExecute 'sudo buildah push shsk2s.azurecr.io/a2a-proxy:latest containers-storage:shsk2s.azurecr.io/a2a-proxy:latest 2>&1').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 30 -CmdToExecute 'sudo buildah push shsk2s.azurecr.io/mcp-preprocessor:latest containers-storage:shsk2s.azurecr.io/mcp-preprocessor:latest 2>&1').Output | Write-Log

    Write-Log '[AI-Assistant] Local proxy images built and available to CRI-O.' -Console
}

<#
.SYNOPSIS
Deploys the Kagent framework (CRDs, controller, UI, tools, PostgreSQL).
This is shared infrastructure used by both copilot and ollama providers.
#>
function Install-KagentFramework {
    [CmdletBinding()]
    Param()

    Write-Log '[AI-Assistant] Deploying Kagent namespace...' -Console
    $nsResult = Invoke-Kubectl -Params 'apply', '-f', (Get-KagentNamespacePath)
    $nsResult.Output | Write-Log
    if (-not $nsResult.Success) {
        throw '[AI-Assistant] Failed to create kagent namespace'
    }

    Write-Log '[AI-Assistant] Deploying local-path StorageClass for Kagent PVCs...' -Console
    $lpResult = Invoke-Kubectl -Params 'apply', '-f', (Get-KagentLocalPathProvisionerPath)
    $lpResult.Output | Write-Log
    if (-not $lpResult.Success) {
        Write-Log '[AI-Assistant] Warning: local-path provisioner apply failed — may already exist.' -Console
    }

    Write-Log '[AI-Assistant] Deploying Kagent CRDs (server-side apply — large resources)...' -Console
    $crdResult = Invoke-Kubectl -Params 'apply', '--server-side', '-f', (Get-KagentCrdsPath)
    $crdResult.Output | Write-Log
    if (-not $crdResult.Success) {
        throw '[AI-Assistant] Failed to apply Kagent CRDs'
    }

    # Wait for CRDs to be established before applying custom resources
    Write-Log '[AI-Assistant] Waiting for Kagent CRDs to be established...' -Console
    $crdWait = Invoke-Kubectl -Params 'wait', '--for=condition=Established',
        'crd/agents.kagent.dev', '--timeout=60s'
    if (-not $crdWait.Success) {
        throw '[AI-Assistant] Kagent CRDs did not become established within 60s'
    }

    Write-Log '[AI-Assistant] Deploying Kagent core (controller, UI, PostgreSQL, tools)...' -Console
    $coreResult = Invoke-Kubectl -Params 'apply', '--server-side', '-f', (Get-KagentCorePath)
    $coreResult.Output | Write-Log
    if (-not $coreResult.Success) {
        throw '[AI-Assistant] Failed to apply Kagent core manifests'
    }

    Write-Log '[AI-Assistant] Applying Kagent ingress for Headlamp integration...' -Console
    $ingResult = Invoke-Kubectl -Params 'apply', '-f', (Get-KagentIngressPath)
    $ingResult.Output | Write-Log
    if (-not $ingResult.Success) {
        Write-Log '[AI-Assistant] Warning: Kagent ingress apply failed — SSE streaming may be impaired.' -Console
    }

    Write-Log '[AI-Assistant] Applying k2s-tools RBAC (read-only cluster access)...' -Console
    $rbacResult = Invoke-Kubectl -Params 'apply', '-f', (Get-KagentToolsRbacPath)
    $rbacResult.Output | Write-Log
    if (-not $rbacResult.Success) {
        Write-Log '[AI-Assistant] Warning: k2s-tools RBAC apply failed.' -Console
    }

    Write-Log '[AI-Assistant] Building local proxy images (a2a-proxy, mcp-preprocessor)...' -Console
    Build-LocalProxyImages

    Write-Log '[AI-Assistant] Deploying mcp-preprocessor (tool output preprocessing proxy)...' -Console
    $mcpResult = Invoke-Kubectl -Params 'apply', '-f', (Get-KagentMcpPreprocessorPath)
    $mcpResult.Output | Write-Log
    if (-not $mcpResult.Success) {
        Write-Log '[AI-Assistant] Warning: mcp-preprocessor apply failed.' -Console
    }

    Write-Log '[AI-Assistant] Deploying a2a-proxy (A2A/shortcut proxy)...' -Console
    $a2aResult = Invoke-Kubectl -Params 'apply', '-f', (Get-KagentA2aProxyPath)
    $a2aResult.Output | Write-Log
    if (-not $a2aResult.Success) {
        Write-Log '[AI-Assistant] Warning: a2a-proxy apply failed.' -Console
    }
}

<#
.SYNOPSIS
Waits for the Kagent controller to become ready.
#>
function Wait-ForKagentAvailable {
    [CmdletBinding()]
    Param(
        [int] $TimeoutSeconds = 300
    )
    Write-Log '[AI-Assistant] Waiting for Kagent controller to be ready...' -Console
    return (Wait-ForPodCondition -Condition Ready `
        -Label 'app.kubernetes.io/component=controller,app.kubernetes.io/name=kagent' `
        -Namespace 'kagent' -TimeoutSeconds $TimeoutSeconds)
}

# ── Provider: Copilot CLI ─────────────────────────────────────────────────────

<#
.SYNOPSIS
Deploys the Copilot CLI BYO agent into Kagent. Requires a GitHub PAT.
#>
function Install-CopilotAgent {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $false)]
        [string] $GithubToken = ''
    )

    Write-Log '[AI-Assistant] Deploying Copilot CLI agent...' -Console

    # Create the GitHub token secret if provided
    if (-not [string]::IsNullOrWhiteSpace($GithubToken)) {
        Write-Log '[AI-Assistant] Creating copilot-github-token secret...' -Console
        # Delete existing secret first (idempotent)
        (Invoke-Kubectl -Params 'delete', 'secret', 'copilot-github-token',
            '-n', 'kagent', '--ignore-not-found').Output | Write-Log
        $secretResult = Invoke-Kubectl -Params 'create', 'secret', 'generic',
            'copilot-github-token', '-n', 'kagent',
            "--from-literal=GITHUB_TOKEN=$GithubToken"
        if (-not $secretResult.Success) {
            throw '[AI-Assistant] Failed to create copilot-github-token secret'
        }
    }
    else {
        # Check if secret already exists
        $existingSecret = (Invoke-Kubectl -Params 'get', 'secret', 'copilot-github-token',
            '-n', 'kagent', '--ignore-not-found', '-o', 'name').Output
        if ([string]::IsNullOrWhiteSpace($existingSecret)) {
            Write-Log '[AI-Assistant] Warning: No GitHub token provided and no existing secret found.' -Console
            Write-Log '[AI-Assistant] The Copilot CLI agent will not work until a token is created:' -Console
            Write-Log '[AI-Assistant]   kubectl create secret generic copilot-github-token -n kagent --from-literal=GITHUB_TOKEN=<your-pat>' -Console
        }
    }

    $agentResult = Invoke-Kubectl -Params 'apply', '-f', (Get-KagentCopilotAgentPath)
    $agentResult.Output | Write-Log
    if (-not $agentResult.Success) {
        throw '[AI-Assistant] Failed to apply Copilot CLI agent manifests'
    }
}

<#
.SYNOPSIS
Removes the Copilot CLI agent resources.
#>
function Remove-CopilotAgent {
    [CmdletBinding()]
    Param()
    Write-Log '[AI-Assistant] Removing Copilot CLI agent resources...' -Console
    (Invoke-Kubectl -Params 'delete', '-f', (Get-KagentCopilotAgentPath), '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'secret', 'copilot-github-token', '-n', 'kagent', '--ignore-not-found').Output | Write-Log
}

# ── Provider: Ollama (local/offline) ──────────────────────────────────────────

<#
.SYNOPSIS
Deploys the Ollama-backed Kagent agent with the specified model name.
#>
function Install-OllamaAgent {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string] $Model
    )

    Write-Log "[AI-Assistant] Deploying Ollama-backed Kagent agent with model '$Model'..." -Console

    $manifestPath = Get-KagentOllamaAgentPath
    $content      = Get-Content -Path $manifestPath -Raw
    $patched      = $content -replace 'MODEL_PLACEHOLDER', $Model

    $tmpFile = [System.IO.Path]::GetTempFileName() + '.yaml'
    Set-Content -Path $tmpFile -Value $patched -Encoding UTF8

    $result = Invoke-Kubectl -Params 'apply', '-f', $tmpFile
    $result.Output | Write-Log
    Remove-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue

    if (-not $result.Success) {
        throw "[AI-Assistant] Failed to apply Ollama agent manifests with model '$Model'"
    }
}

<#
.SYNOPSIS
Removes the Ollama-backed agent resources from Kagent.
#>
function Remove-OllamaAgent {
    [CmdletBinding()]
    Param()
    Write-Log '[AI-Assistant] Removing Ollama agent resources from Kagent...' -Console
    (Invoke-Kubectl -Params 'delete', '-f', (Get-KagentOllamaAgentPath), '--ignore-not-found').Output | Write-Log
}

# ── Ollama Deployment (shared for ollama provider) ────────────────────────────

<#
.SYNOPSIS
Creates the /data/ollama directory on the kubemaster Linux node via SSH.
Idempotent — safe to call when the directory already exists.
#>
function New-OllamaDataDirectory {
    [CmdletBinding()]
    Param()
    Write-Log '[AI-Assistant] Creating /data/ollama on kubemaster...' -Console
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 10 -CmdToExecute 'sudo mkdir -m 777 -p /data/ollama').Output | Write-Log
    Write-Log '[AI-Assistant] /data/ollama directory ready.' -Console
}

<#
.SYNOPSIS
Creates (or updates) the 'zscaler-ca' ConfigMap in the ai-assistant namespace.
Idempotent — safe to call when the ConfigMap already exists.
#>
function New-ZscalerCaConfigMap {
    [CmdletBinding()]
    Param()

    Write-Log '[AI-Assistant] Creating ZScaler CA ConfigMap for Ollama proxy trust...' -Console

    $certPath = "$PSScriptRoot/../../lib/modules/k2s/k2s.node.module/linuxnode/setup/certificate/ZScalerRootCA.crt"
    $certPath = [System.IO.Path]::GetFullPath($certPath)

    if (-not (Test-Path $certPath)) {
        Write-Log "[AI-Assistant] Warning: ZScaler CA cert not found at '$certPath' — skipping ConfigMap." -Console
        return
    }

    # Ensure the namespace exists before creating the ConfigMap
    $nsResult = Invoke-Kubectl -Params 'create', 'namespace', 'ai-assistant', '--dry-run=client', '-o', 'yaml'
    $nsTmpYaml = [System.IO.Path]::GetTempFileName() + '.yaml'
    $nsResult.Output | Set-Content $nsTmpYaml -Encoding UTF8
    (Invoke-Kubectl -Params 'apply', '-f', $nsTmpYaml).Output | Write-Log
    Remove-Item $nsTmpYaml -Force -ErrorAction SilentlyContinue

    # Strip SPDX header lines — keep only the PEM block
    $lines = Get-Content $certPath
    $pemLines = $lines | Where-Object { $_ -notmatch '^\s*#' }
    $tmpPem = [System.IO.Path]::GetTempFileName() + '.pem'
    $pemLines | Set-Content $tmpPem -Encoding ASCII

    $r = Invoke-Kubectl -Params 'create', 'configmap', 'zscaler-ca',
        '-n', 'ai-assistant',
        "--from-file=ZScalerRootCA.pem=$tmpPem",
        '--dry-run=client', '-o', 'yaml'
    $tmpYaml = [System.IO.Path]::GetTempFileName() + '.yaml'
    $r.Output | Set-Content $tmpYaml -Encoding UTF8
    (Invoke-Kubectl -Params 'apply', '-f', $tmpYaml).Output | Write-Log
    Remove-Item $tmpYaml, $tmpPem -Force -ErrorAction SilentlyContinue

    Write-Log '[AI-Assistant] ZScaler CA ConfigMap ready.' -Console
}

<#
.SYNOPSIS
Pulls an Ollama model by running 'ollama pull' inside the Ollama pod.
#>
function Invoke-OllamaModelPull {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string] $Model
    )

    Write-Log "[AI-Assistant] Waiting for Ollama pod to be ready..." -Console
    $ollamaReady = Wait-ForPodCondition -Condition Ready -Label 'app=ollama' -Namespace 'ai-assistant' -TimeoutSeconds 1600
    if (-not $ollamaReady) {
        throw '[AI-Assistant] Ollama pod did not become ready within 1600s. Check: kubectl describe pod -n ai-assistant -l app=ollama'
    }

    Write-Log "[AI-Assistant] Pulling Ollama model '$Model' (kubectl exec into pod)..." -Console
    Write-Log "[AI-Assistant] (This may take several minutes for a new model — existing models complete in seconds)" -Console

    $pullResult = Invoke-Kubectl -Params 'exec', '-n', 'ai-assistant', 'deployment/ollama',
        '--', 'ollama', 'pull', $Model
    $pullResult.Output | Write-Log

    if (-not $pullResult.Success) {
        throw "[AI-Assistant] 'ollama pull $Model' failed. See log for details."
    }
    Write-Log "[AI-Assistant] Model '$Model' pulled successfully." -Console
}

# ── Kagent Proxy Service for Headlamp ─────────────────────────────────────────

<#
.SYNOPSIS
Configures Ollama keep_alive to prevent cold-start model unloading during active usage.
Sends a lightweight generate request with keep_alive parameter to pin the model in memory.
Gracefully degrades if Ollama is not reachable (non-fatal).
.PARAMETER Model
The model name to keep alive.
.PARAMETER KeepAlive
Duration string for keep_alive (default: "30m"). Set to "0" to disable.
#>
function Set-OllamaKeepAlive {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string] $Model,
        [Parameter(Mandatory = $false)]
        [string] $KeepAlive = '30m'
    )

    Write-Log "[AI-Assistant] Setting Ollama keep_alive=$KeepAlive for model '$Model'..." -Console

    # Use kubectl exec to curl the Ollama API from inside the cluster
    $payload = @{ model = $Model; keep_alive = $KeepAlive; prompt = ''; stream = $false } | ConvertTo-Json -Compress
    $curlCmd = "curl -s -X POST http://172.19.1.1:11434/api/generate -H 'Content-Type: application/json' -d '$payload' --max-time 10"

    $result = Invoke-CmdOnControlPlaneViaSSHKey -Timeout 15 -CmdToExecute $curlCmd
    if ($result.Output -match '"done"') {
        Write-Log "[AI-Assistant] Ollama keep_alive configured: model '$Model' will stay loaded for $KeepAlive." -Console
    }
    else {
        Write-Log "[AI-Assistant] Warning: Could not set Ollama keep_alive (non-fatal). Model may unload after idle timeout." -Console
        Write-Log "[AI-Assistant] Ollama response: $($result.Output)" -Console
    }
}

# ── Kagent Proxy Service for Headlamp ──────────────────────────────────────────

<#
.SYNOPSIS
No-op — the Headlamp AI Assistant plugin is patched at deploy time (via the
ai-assistant-kagent-patch initContainer) to call a2a-proxy:8082 in the kagent
namespace directly. No additional proxy service is needed.
Previously this created a legacy ExternalName service which is no longer used.
#>
function Set-KagentProxyService {
    [CmdletBinding()]
    Param()
    Write-Log '[AI-Assistant] Plugin patched to use a2a-proxy.kagent directly — no proxy service needed.' -Console
}

<#
.SYNOPSIS
Removes any legacy proxy services from previous addon versions.
#>
function Remove-KagentProxyService {
    [CmdletBinding()]
    Param()
    Write-Log '[AI-Assistant] Removing any legacy proxy services...' -Console
    # Legacy K8s resource names from pre-Kagent era — must match actual cluster objects
    foreach ($svcName in @('holmesgpt-holmes', 'kagent-proxy')) {
        (Invoke-Kubectl -Params 'delete', 'service', $svcName, '-n', 'default', '--ignore-not-found').Output | Write-Log
    }
}

# ── Cleanup: Legacy agent resources ────────────────────────────────────────

<#
.SYNOPSIS
Removes legacy agent resources from previous addon versions (pre-Kagent era).
Called during enable/update to clean up before deploying Kagent.
The resource names below are actual K8s object names that exist in clusters
upgrading from the old version — they must match exactly.
#>
function Remove-LegacyAgentResources {
    [CmdletBinding()]
    Param()
    Write-Log '[AI-Assistant] Cleaning up legacy agent resources (if any)...' -Console

    # Resource kind → (name, namespace) pairs for legacy objects
    $legacyResources = @(
        # default namespace: old Python proxy + wiring
        @{ Kind = 'deployment';     Name = 'holmesgpt-proxy';        Namespace = 'default' }
        @{ Kind = 'configmap';      Name = 'holmesgpt-proxy-config'; Namespace = 'default' }
        @{ Kind = 'configmap';      Name = 'holmesgpt-nginx-conf';   Namespace = 'default' }
        @{ Kind = 'endpointslice';  Name = 'holmesgpt-holmes-k2s';   Namespace = 'default' }
        @{ Kind = 'endpoints';      Name = 'holmesgpt-holmes';       Namespace = 'default' }
        # ai-assistant namespace: old agent deployment + config
        @{ Kind = 'deployment';     Name = 'holmesgpt-holmes';           Namespace = 'ai-assistant' }
        @{ Kind = 'service';        Name = 'holmesgpt-holmes';           Namespace = 'ai-assistant' }
        @{ Kind = 'configmap';      Name = 'holmesgpt-model-config';     Namespace = 'ai-assistant' }
        @{ Kind = 'configmap';      Name = 'holmesgpt-prompt-overrides'; Namespace = 'ai-assistant' }
        @{ Kind = 'configmap';      Name = 'holmesgpt-toolset-overrides';Namespace = 'ai-assistant' }
        @{ Kind = 'serviceaccount'; Name = 'holmesgpt';                  Namespace = 'ai-assistant' }
        # ai-assistant namespace: old SSE ingress
        @{ Kind = 'ingress';        Name = 'holmesgpt-sse-direct';       Namespace = 'ai-assistant' }
        @{ Kind = 'service';        Name = 'holmesgpt-proxy-bridge';     Namespace = 'ai-assistant' }
    )
    foreach ($r in $legacyResources) {
        (Invoke-Kubectl -Params 'delete', $r.Kind, $r.Name, '-n', $r.Namespace, '--ignore-not-found').Output | Write-Log
    }

    # Cluster-scoped RBAC (no namespace)
    foreach ($rbac in @(
        @{ Kind = 'clusterrolebinding'; Name = 'holmesgpt-reader' }
        @{ Kind = 'clusterrole';        Name = 'holmesgpt-reader' }
    )) {
        (Invoke-Kubectl -Params 'delete', $rbac.Kind, $rbac.Name, '--ignore-not-found').Output | Write-Log
    }
}

# ── Full resource removal ─────────────────────────────────────────────────────

<#
.SYNOPSIS
Removes all ai-assistant addon resources. Optionally keeps the Ollama model PVC.
#>
function Remove-AiAssistantResources {
    [CmdletBinding()]
    Param(
        [switch] $KeepModelData = $false
    )

    # ── Kagent agent resources ─────────────────────────────────────────────────
    Remove-CopilotAgent
    Remove-OllamaAgent
    Remove-KagentProxyService

    # ── Kagent framework ───────────────────────────────────────────────────
    Write-Log '[AI-Assistant] Removing a2a-proxy...' -Console
    (Invoke-Kubectl -Params 'delete', '-f', (Get-KagentA2aProxyPath), '--ignore-not-found').Output | Write-Log

    Write-Log '[AI-Assistant] Removing mcp-preprocessor...' -Console
    (Invoke-Kubectl -Params 'delete', '-f', (Get-KagentMcpPreprocessorPath), '--ignore-not-found').Output | Write-Log

    Write-Log '[AI-Assistant] Removing k2s-tools RBAC...' -Console
    (Invoke-Kubectl -Params 'delete', '-f', (Get-KagentToolsRbacPath), '--ignore-not-found').Output | Write-Log

    Write-Log '[AI-Assistant] Removing Kagent ingress...' -Console
    (Invoke-Kubectl -Params 'delete', '-f', (Get-KagentIngressPath), '--ignore-not-found').Output | Write-Log

    Write-Log '[AI-Assistant] Removing Kagent core...' -Console
    (Invoke-Kubectl -Params 'delete', '-f', (Get-KagentCorePath), '--ignore-not-found').Output | Write-Log

    Write-Log '[AI-Assistant] Removing Kagent CRDs...' -Console
    (Invoke-Kubectl -Params 'delete', '-f', (Get-KagentCrdsPath), '--ignore-not-found').Output | Write-Log

    Write-Log '[AI-Assistant] Removing local-path provisioner...' -Console
    (Invoke-Kubectl -Params 'delete', '-f', (Get-KagentLocalPathProvisionerPath), '--ignore-not-found').Output | Write-Log

    Write-Log '[AI-Assistant] Removing Kagent namespace...' -Console
    (Invoke-Kubectl -Params 'delete', 'namespace', 'kagent', '--ignore-not-found').Output | Write-Log

    # ── Legacy agent cleanup (in case of upgrade from old version) ──────────────
    Remove-LegacyAgentResources

    # ── Ollama ─────────────────────────────────────────────────────────────────
    Write-Log '[AI-Assistant] Removing Ollama resources...' -Console
    (Invoke-Kubectl -Params 'delete', 'deployment',     'ollama', '-n', 'ai-assistant', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'service',        'ollama', '-n', 'ai-assistant', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'serviceaccount', 'ollama', '-n', 'ai-assistant', '--ignore-not-found').Output | Write-Log

    if ($KeepModelData) {
        Write-Log '[AI-Assistant] Ollama PVC/PV preserved — namespace kept for PVC residency.' -Console
    }
    else {
        (Invoke-Kubectl -Params 'delete', 'pvc', 'ollama-models', '-n', 'ai-assistant', '--ignore-not-found').Output | Write-Log
        (Invoke-Kubectl -Params 'delete', 'pv', 'ollama-models-pv', '--ignore-not-found').Output | Write-Log
        Write-Log '[AI-Assistant] Deleting ai-assistant namespace...' -Console
        (Invoke-Kubectl -Params 'delete', 'namespace', 'ai-assistant', '--ignore-not-found').Output | Write-Log
    }
}

# ── User-facing output ────────────────────────────────────────────────────────

<#
.SYNOPSIS
Writes post-installation usage notes for the AI Assistant addon.
#>
function Write-AiAssistantUsageForUser {
    [CmdletBinding()]
    Param(
        [string] $Provider = 'copilot',
        [string] $Model = 'qwen2.5:7b'
    )

    $providerInfo = if ($Provider -eq 'ollama') {
        @"
  Provider: Ollama (local/offline)
  Agent:    k2s-assistant (Kagent + Ollama, model: $Model)
  No external connectivity required.
"@
    }
    else {
        @"
  Provider: Copilot CLI (connected)
  Agent:    copilot-cli (Kagent + GitHub Copilot CLI)
  Requires: GitHub PAT with "Copilot Requests" permission.
"@
    }

    @"

                AI ASSISTANT ADDON - USAGE NOTES

 The AI Assistant addon has deployed:
   - Kagent framework (namespace: kagent)
$providerInfo

 Kagent A2A API:
   Internal: http://kagent-controller.kagent.svc.cluster.local:8083/api/a2a/kagent/<agent-name>
   Ingress:  http://<node-ip>/kagent/api/a2a/kagent/<agent-name>

 Kagent UI:
   Access via: kubectl port-forward svc/kagent-ui -n kagent 8080:8080
   Then open: http://localhost:8080

 To use with Headlamp:
   1. Open the Headlamp dashboard:
      k2s addons status dashboard   (shows the URL / port-forward command)
   2. Click the AI icon in the top-right app bar of Headlamp.
   3. The AI Assistant plugin connects to Kagent via the K8s apiserver proxy.

 To check agent status:
   kubectl get agents -n kagent
   kubectl get pods -n kagent

"@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
}

function Write-BrowserWarningForUser {
    @"

 ⚠  BROWSER NOTE: Use Chrome, Edge, or Firefox. Safari may block SSE streams.

"@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
}

# ── Module exports ────────────────────────────────────────────────────────────

Export-ModuleMember -Function `
    Get-AiAssistantManifestsDir, Get-OllamaManifestPath, `
    Get-KagentManifestsDir, Get-KagentNamespacePath, Get-KagentCrdsPath, `
    Get-KagentCorePath, Get-KagentLocalPathProvisionerPath, `
    Get-KagentA2aProxyPath, Get-KagentMcpPreprocessorPath, Get-KagentToolsRbacPath, `
    Get-KagentCopilotAgentPath, Get-KagentOllamaAgentPath, Get-KagentIngressPath, `
    Install-KagentFramework, Wait-ForKagentAvailable, Build-LocalProxyImages, `
    Install-CopilotAgent, Remove-CopilotAgent, `
    Install-OllamaAgent, Remove-OllamaAgent, `
    New-OllamaDataDirectory, New-ZscalerCaConfigMap, Invoke-OllamaModelPull, `
    Set-OllamaKeepAlive, `
    Set-KagentProxyService, Remove-KagentProxyService, `
    Remove-LegacyAgentResources, Remove-AiAssistantResources, `
    Write-AiAssistantUsageForUser, Write-BrowserWarningForUser
`
