# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
AI Assistant addon module — provider-abstracted backend for K2s AI integration.

.DESCRIPTION
Supports two agent providers:
  - 'copilot'  : Kagent + Copilot CLI BYO agent (connected, requires GitHub PAT)
  - 'ollama'   : Kagent + Ollama local model (offline/air-gapped, no external deps)

Both providers deploy the Kagent framework (controller, UI, tools, PostgreSQL)
as the agent orchestration layer. The Kagent UI serves as the sole AI interface.
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

    Write-Log '[AI-Assistant] Applying Kagent ingress for external access...' -Console
    $ingResult = Invoke-Kubectl -Params 'apply', '-f', (Get-KagentIngressPath)
    $ingResult.Output | Write-Log
    if (-not $ingResult.Success) {
        Write-Log '[AI-Assistant] Warning: Kagent ingress apply failed — external access may be impaired.' -Console
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

# ── Windows Ollama Runtime Management ─────────────────────────────────────────

$script:OllamaServiceName = 'K2sOllama'

<#
.SYNOPSIS
Returns the path to the Ollama executable on the Windows host.
#>
function Get-OllamaExePath {
    [CmdletBinding()]
    Param()
    $ollamaCmd = Get-Command 'ollama' -ErrorAction SilentlyContinue
    if ($ollamaCmd) { return $ollamaCmd.Source }
    $defaultPath = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
    if (Test-Path $defaultPath) { return $defaultPath }
    throw '[AI-Assistant] Ollama is not installed. Install from https://ollama.com/download/windows'
}

<#
.SYNOPSIS
Ensures Ollama is running as a Windows service with auto-start and auto-restart.
Uses nssm to create a resilient service from the Ollama executable.
Idempotent — safe to call if service already exists.
#>
function Install-OllamaWindowsService {
    [CmdletBinding()]
    Param()

    $nssmExe = "$PSScriptRoot\..\..\bin\nssm.exe"
    $ollamaExe = Get-OllamaExePath
    $svcName = $script:OllamaServiceName

    Write-Log "[AI-Assistant] Configuring Ollama as Windows service '$svcName'..." -Console

    # Check if service already exists and Ollama is responding
    $existingSvc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($existingSvc) {
        $alreadyHealthy = Test-OllamaWindowsHealth
        if ($alreadyHealthy) {
            Write-Log "[AI-Assistant] Service '$svcName' already running and healthy." -Console
            return
        }
    }

    # Stop the desktop Ollama app (tray app) — we'll manage it via service
    $ollamaProcesses = Get-Process -Name 'ollama' -ErrorAction SilentlyContinue
    if ($ollamaProcesses -and -not $existingSvc) {
        Write-Log '[AI-Assistant] Stopping Ollama desktop app (will run as service instead)...' -Console
        $ollamaProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    # Install service via nssm if not already installed
    if (-not $existingSvc) {
        Write-Log "[AI-Assistant] Installing service via nssm..." -Console
        & $nssmExe install $svcName $ollamaExe serve 2>&1 | Write-Log
        & $nssmExe set $svcName DisplayName 'K2s Ollama LLM Service' 2>&1 | Write-Log
        & $nssmExe set $svcName Description 'Local LLM runtime for K2s AI Assistant addon' 2>&1 | Write-Log
        & $nssmExe set $svcName Start SERVICE_AUTO_START 2>&1 | Write-Log
        & $nssmExe set $svcName AppRestartDelay 5000 2>&1 | Write-Log
        & $nssmExe set $svcName AppExit Default Restart 2>&1 | Write-Log
        # Environment: bind to all interfaces
        & $nssmExe set $svcName AppEnvironmentExtra "OLLAMA_HOST=0.0.0.0" 2>&1 | Write-Log
        & $nssmExe set $svcName AppStdout "$env:LOCALAPPDATA\K2s\logs\ollama-stdout.log" 2>&1 | Write-Log
        & $nssmExe set $svcName AppStderr "$env:LOCALAPPDATA\K2s\logs\ollama-stderr.log" 2>&1 | Write-Log
        & $nssmExe set $svcName AppRotateFiles 1 2>&1 | Write-Log
        & $nssmExe set $svcName AppRotateBytes 10485760 2>&1 | Write-Log

        # Ensure log directory exists
        New-Item -ItemType Directory -Path "$env:LOCALAPPDATA\K2s\logs" -Force | Out-Null
    }

    # Start the service
    Write-Log "[AI-Assistant] Starting service '$svcName'..." -Console
    Start-Service -Name $svcName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3

    # Verify Ollama is actually responding (nssm may report 'Paused' for apps that
    # don't implement SCM pause protocol — this is normal for Ollama)
    $ready = Wait-ForOllamaReady -TimeoutSeconds 15
    if (-not $ready) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        throw "[AI-Assistant] Failed to start Ollama service. Status: $($svc.Status). Check: nssm status $svcName"
    }
    Write-Log "[AI-Assistant] Ollama service running (PID: $((Get-Process ollama -ErrorAction SilentlyContinue | Select-Object -First 1).Id))." -Console
}

<#
.SYNOPSIS
Stops and optionally removes the Ollama Windows service.
#>
function Remove-OllamaWindowsService {
    [CmdletBinding()]
    Param(
        [switch] $KeepInstalled = $false
    )
    $svcName = $script:OllamaServiceName
    $nssmExe = "$PSScriptRoot\..\..\bin\nssm.exe"

    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Log "[AI-Assistant] Service '$svcName' not found — nothing to remove." -Console
        return
    }

    Write-Log "[AI-Assistant] Stopping Ollama service..." -Console
    Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    if (-not $KeepInstalled) {
        Write-Log "[AI-Assistant] Removing Ollama service..." -Console
        & $nssmExe remove $svcName confirm 2>&1 | Write-Log
    }
}

<#
.SYNOPSIS
Configures Windows Firewall to allow inbound connections to Ollama from the K2s bridge network.
Idempotent — safe to call if rule already exists.
#>
function Set-OllamaFirewallRule {
    [CmdletBinding()]
    Param()
    $ruleName = 'K2s-Ollama-Inbound'
    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log "[AI-Assistant] Firewall rule '$ruleName' already exists." -Console
        return
    }
    Write-Log "[AI-Assistant] Adding firewall rule '$ruleName' (TCP 11434 from K2s subnets)..." -Console
    New-NetFirewallRule -DisplayName $ruleName `
        -Direction Inbound -Action Allow -Protocol TCP -LocalPort 11434 `
        -RemoteAddress @('172.19.0.0/16', '172.20.0.0/16', '172.21.0.0/16') `
        -Description 'Allow Ollama LLM access from K2s Kubernetes pods' | Out-Null
    Write-Log "[AI-Assistant] Firewall rule created." -Console
}

<#
.SYNOPSIS
Removes the Ollama firewall rule.
#>
function Remove-OllamaFirewallRule {
    [CmdletBinding()]
    Param()
    $ruleName = 'K2s-Ollama-Inbound'
    Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    Write-Log "[AI-Assistant] Firewall rule '$ruleName' removed." -Console
}

<#
.SYNOPSIS
Waits for Ollama to be reachable on the host.
#>
function Wait-ForOllamaReady {
    [CmdletBinding()]
    Param(
        [int] $TimeoutSeconds = 60
    )
    Write-Log "[AI-Assistant] Waiting for Ollama to be ready at http://localhost:11434..." -Console
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = curl.exe -s http://localhost:11434/api/tags --max-time 3 2>&1
            if ($r -match '"models"') {
                Write-Log "[AI-Assistant] Ollama is ready." -Console
                return $true
            }
        }
        catch {}
        Start-Sleep -Seconds 2
    }
    return $false
}

<#
.SYNOPSIS
Pulls an Ollama model on the Windows host.
#>
function Invoke-OllamaModelPull {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string] $Model
    )

    # Ensure Ollama is ready
    $ready = Wait-ForOllamaReady -TimeoutSeconds 30
    if (-not $ready) {
        throw '[AI-Assistant] Ollama is not responding on localhost:11434. Check service status.'
    }

    # Check if model already exists
    $tags = curl.exe -s http://localhost:11434/api/tags --max-time 5 2>&1
    if ($tags -match [regex]::Escape($Model)) {
        Write-Log "[AI-Assistant] Model '$Model' already available — skipping pull." -Console
        return
    }

    Write-Log "[AI-Assistant] Pulling Ollama model '$Model'..." -Console
    Write-Log "[AI-Assistant] (This may take several minutes for new models)" -Console

    $ollamaExe = Get-OllamaExePath
    & $ollamaExe pull $Model 2>&1 | ForEach-Object { Write-Log "[AI-Assistant] $_" }

    # Verify
    $tags = curl.exe -s http://localhost:11434/api/tags --max-time 5 2>&1
    if ($tags -notmatch [regex]::Escape($Model)) {
        throw "[AI-Assistant] Model '$Model' pull did not complete successfully."
    }
    Write-Log "[AI-Assistant] Model '$Model' ready." -Console
}

<#
.SYNOPSIS
Checks if Ollama is running and responsive on the Windows host.
Returns $true if healthy.
#>
function Test-OllamaWindowsHealth {
    [CmdletBinding()]
    Param()
    try {
        $r = curl.exe -s http://localhost:11434/api/tags --max-time 3 2>&1
        return ($r -match '"models"')
    }
    catch {
        return $false
    }
}

# ── Ollama Keep-Alive ──────────────────────────────────────────────────────────

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

    # Use curl directly from host since Ollama is accessible on the bridge interface (172.19.1.1:11434)
    $payload = @{ model = $Model; keep_alive = $KeepAlive; prompt = ''; stream = $false } | ConvertTo-Json -Compress
    $payloadFile = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($payloadFile, $payload)
        $curlExe = "$PSScriptRoot\..\..\bin\curl.exe"
        if (-not (Test-Path $curlExe)) { $curlExe = 'curl.exe' }
        $curlResult = & $curlExe -s -X POST 'http://172.19.1.1:11434/api/generate' -H 'Content-Type: application/json' -d "@$payloadFile" --max-time 10 2>&1
        $output = $curlResult -join ''
    }
    finally {
        Remove-Item -Path $payloadFile -Force -ErrorAction SilentlyContinue
    }

    if ($output -match '"done"') {
        Write-Log "[AI-Assistant] Ollama keep_alive configured: model '$Model' will stay loaded for $KeepAlive." -Console
    }
    else {
        Write-Log "[AI-Assistant] Warning: Could not set Ollama keep_alive (non-fatal). Model may unload after idle timeout." -Console
        Write-Log "[AI-Assistant] Ollama response: $output" -Console
    }
}

# ── Legacy Proxy Cleanup ──────────────────────────────────────────────────────

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
        # kagent namespace: obsolete Headlamp SSE direct-route ingress
        @{ Kind = 'ingress';        Name = 'kagent-sse-direct';          Namespace = 'kagent' }
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

    # ── Ollama (Windows service) ─────────────────────────────────────────────────
    Write-Log '[AI-Assistant] Removing Ollama Windows service...' -Console
    Remove-OllamaWindowsService -KeepInstalled:$KeepModelData
    Remove-OllamaFirewallRule

    # Clean up any legacy K8s Ollama resources (from older versions)
    (Invoke-Kubectl -Params 'delete', 'deployment',     'ollama', '-n', 'ai-assistant', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'service',        'ollama', '-n', 'ai-assistant', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'serviceaccount', 'ollama', '-n', 'ai-assistant', '--ignore-not-found').Output | Write-Log

    if ($KeepModelData) {
        Write-Log '[AI-Assistant] Ollama models preserved on Windows host.' -Console
    }
    else {
        (Invoke-Kubectl -Params 'delete', 'pvc', 'ollama-models', '-n', 'ai-assistant', '--ignore-not-found').Output | Write-Log
        (Invoke-Kubectl -Params 'delete', 'pv', 'ollama-models-pv', '--ignore-not-found').Output | Write-Log
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

 Kagent UI (primary AI interface):
   Ingress:  https://k2s.cluster.local/agents/kagent/k2s-assistant/chat
   Or via port-forward:
     kubectl port-forward svc/kagent-ui -n kagent 8080:8080
     Then open: http://localhost:8080


 To check agent status:
   kubectl get agents -n kagent
   kubectl get pods -n kagent


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
    Install-OllamaWindowsService, Remove-OllamaWindowsService, `
    Set-OllamaFirewallRule, Remove-OllamaFirewallRule, `
    Wait-ForOllamaReady, Test-OllamaWindowsHealth, `
    Get-OllamaExePath, Invoke-OllamaModelPull, `
    Set-OllamaKeepAlive, `
    Remove-KagentProxyService, `
    Remove-LegacyAgentResources, Remove-AiAssistantResources, `
    Write-AiAssistantUsageForUser
`
