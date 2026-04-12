# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$infraModule    = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule  = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$nodeModule     = "$PSScriptRoot/../../lib/modules/k2s/k2s.node.module/k2s.node.module.psm1"
$addonsModule   = "$PSScriptRoot\..\addons.module.psm1"

Import-Module $infraModule, $clusterModule, $nodeModule, $addonsModule

function Get-AiAssistantManifestsDir {
    return "$PSScriptRoot\manifests"
}

function Get-OllamaManifestPath {
    return "$PSScriptRoot\manifests\ollama\ollama.yaml"
}

function Get-HolmesManifestPath {
    return "$PSScriptRoot\manifests\holmesgpt\holmesgpt.yaml"
}

function Get-HolmesSseIngressPath {
    return "$PSScriptRoot\manifests\holmesgpt\holmesgpt-sse-ingress.yaml"
}

<#
.SYNOPSIS
Patches the HolmesGPT model ConfigMap with the chosen Ollama model name then re-applies it.
#>
function Set-HolmesModelConfig {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string] $Model
    )

    $manifestPath = Get-HolmesManifestPath
    $content      = Get-Content -Path $manifestPath -Raw
    $patched      = $content -replace 'MODEL_PLACEHOLDER', $Model

    $tmpFile = [System.IO.Path]::GetTempFileName() + '.yaml'
    Set-Content -Path $tmpFile -Value $patched -Encoding UTF8

    $result = Invoke-Kubectl -Params 'apply', '-f', $tmpFile
    $result.Output | Write-Log
    Remove-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue

    if (-not $result.Success) {
        throw "[AI-Assistant] Failed to apply HolmesGPT manifests with model '$Model'"
    }
}

<#
.SYNOPSIS
Deploys a lightweight nginx reverse-proxy pod + selector-based Service in the 'default'
namespace that forwards to the real HolmesGPT service in 'ai-assistant'.

BACKGROUND
The Headlamp AI Assistant plugin hardcodes HOLMES_SERVICE_NAMESPACE='default' and uses
the K8s API server proxy path:
  /api/v1/namespaces/default/services/holmesgpt-holmes:80/proxy/...

K8s 1.35 apiserver proxy validation requires:
  1. The Service must have a spec.selector (selectorless ClusterIP → NotFound).
  2. Endpoint addresses must have a valid targetRef whose namespace matches the
     Endpoints namespace — cross-namespace pod refs are rejected.

The only correct cross-namespace proxy approach is therefore a real pod running in
'default' that relays traffic to 'ai-assistant'. We use nginx:alpine (already present
on every K2s node as part of the ingress addon image set).

Architecture:
  Headlamp plugin
    → K8s apiserver proxy (/namespaces/default/services/holmesgpt-holmes:80/proxy/...)
    → nginx pod in 'default' (selector: app=holmesgpt-proxy)
    → holmesgpt-holmes.ai-assistant.svc.cluster.local:80
    → HolmesGPT pod in 'ai-assistant'
#>
function Set-HolmesProxyEndpoints {
    [CmdletBinding()]
    Param()

    Write-Log '[AI-Assistant] Deploying HolmesGPT nginx reverse-proxy in default namespace...' -Console

    # Clean up legacy resources from older versions
    (Invoke-Kubectl -Params 'delete', 'endpointslice', 'holmesgpt-holmes-k2s', '-n', 'default', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'endpoints',     'holmesgpt-holmes',     '-n', 'default', '--ignore-not-found').Output | Write-Log

    # nginx.conf — proxy_pass to the HolmesGPT service in ai-assistant namespace.
    # Variables written with single-quoted string to avoid PowerShell interpolation.
    $nginxConf  = 'events {}' + [System.Environment]::NewLine
    $nginxConf += 'http {' + [System.Environment]::NewLine
    $nginxConf += '  server {' + [System.Environment]::NewLine
    $nginxConf += '    listen 80;' + [System.Environment]::NewLine
    $nginxConf += '    location / {' + [System.Environment]::NewLine
    $nginxConf += '      proxy_pass http://holmesgpt-holmes.ai-assistant.svc.cluster.local:80;' + [System.Environment]::NewLine
    $nginxConf += '      proxy_http_version 1.1;' + [System.Environment]::NewLine
    $nginxConf += '      proxy_set_header Host $host;' + [System.Environment]::NewLine
    $nginxConf += '      proxy_set_header X-Real-IP $remote_addr;' + [System.Environment]::NewLine
    $nginxConf += '      proxy_set_header Connection "";' + [System.Environment]::NewLine
    $nginxConf += '      proxy_buffering off;' + [System.Environment]::NewLine
    $nginxConf += '      proxy_read_timeout 600s;' + [System.Environment]::NewLine
    $nginxConf += '      proxy_send_timeout 600s;' + [System.Environment]::NewLine
    $nginxConf += '    }' + [System.Environment]::NewLine
    $nginxConf += '  }' + [System.Environment]::NewLine
    $nginxConf += '}'

    $tmpConf = [System.IO.Path]::GetTempFileName() + '.conf'
    [System.IO.File]::WriteAllText($tmpConf, $nginxConf, [System.Text.Encoding]::ASCII)

    # Create/update the ConfigMap from the conf file
    $cmResult = Invoke-Kubectl -Params 'create', 'configmap', 'holmesgpt-nginx-conf',
        '-n', 'default',
        "--from-file=nginx.conf=$tmpConf",
        '--dry-run=client', '-o', 'yaml'
    $tmpYaml = [System.IO.Path]::GetTempFileName() + '.yaml'
    $cmResult.Output | Set-Content $tmpYaml -Encoding UTF8
    (Invoke-Kubectl -Params 'apply', '-f', $tmpYaml).Output | Write-Log
    Remove-Item $tmpYaml, $tmpConf -Force -ErrorAction SilentlyContinue

    # Deployment + Service manifests
    $manifest = @"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: holmesgpt-proxy
  namespace: default
  labels:
    app: holmesgpt-proxy
    app.kubernetes.io/part-of: ai-assistant
    app.kubernetes.io/managed-by: k2s
spec:
  replicas: 1
  selector:
    matchLabels:
      app: holmesgpt-proxy
  template:
    metadata:
      labels:
        app: holmesgpt-proxy
        app.kubernetes.io/part-of: ai-assistant
    spec:
      nodeSelector:
        kubernetes.io/os: linux
      containers:
        - name: nginx
          image: nginx:alpine
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 80
          volumeMounts:
            - name: nginx-conf
              mountPath: /etc/nginx/nginx.conf
              subPath: nginx.conf
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              cpu: 100m
              memory: 64Mi
      volumes:
        - name: nginx-conf
          configMap:
            name: holmesgpt-nginx-conf
---
apiVersion: v1
kind: Service
metadata:
  name: holmesgpt-holmes
  namespace: default
  labels:
    app.kubernetes.io/name: holmesgpt
    app.kubernetes.io/part-of: ai-assistant
    app.kubernetes.io/managed-by: k2s
  annotations:
    k2s.ai-assistant/proxy-target: "holmesgpt-holmes.ai-assistant.svc.cluster.local"
spec:
  type: ClusterIP
  selector:
    app: holmesgpt-proxy
  ports:
    - name: agui
      port: 80
      targetPort: 80
      protocol: TCP
"@

    $tmpFile = [System.IO.Path]::GetTempFileName() + '.yaml'
    Set-Content -Path $tmpFile -Value $manifest -Encoding UTF8
    $result = Invoke-Kubectl -Params 'apply', '-f', $tmpFile
    $result.Output | Write-Log
    Remove-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue

    if (-not $result.Success) {
        throw '[AI-Assistant] Failed to apply HolmesGPT proxy deployment/service in default namespace'
    }

    Write-Log '[AI-Assistant] Waiting for HolmesGPT proxy pod to be ready...' -Console
    $ready = Wait-ForPodCondition -Condition Ready -Label 'app=holmesgpt-proxy' -Namespace 'default' -TimeoutSeconds 60
    if (-not $ready) {
        Write-Log '[AI-Assistant] Warning: HolmesGPT proxy pod did not become ready within 60s. Check: kubectl get pods -n default -l app=holmesgpt-proxy' -Console
    } else {
        Write-Log '[AI-Assistant] HolmesGPT nginx reverse-proxy is ready.' -Console
    }

    # ── SSE Direct-Route Ingress ───────────────────────────────────────────────
    # Bypasses the K8s apiserver service proxy (which buffers SSE streams) by
    # routing the HolmesGPT path directly from ingress-nginx to holmesgpt-holmes
    # in ai-assistant namespace with proxy-buffering off.
    Write-Log '[AI-Assistant] Applying SSE direct-route ingress...' -Console
    $sseResult = Invoke-Kubectl -Params 'apply', '-f', (Get-HolmesSseIngressPath)
    $sseResult.Output | Write-Log
    if (-not $sseResult.Success) {
        # Non-fatal: the nginx proxy still works; SSE streaming may be impaired
        Write-Log '[AI-Assistant] Warning: Failed to apply SSE ingress. SSE streaming may buffer. Check: kubectl get ingress -n ai-assistant' -Console
    } else {
        Write-Log '[AI-Assistant] SSE direct-route ingress applied.' -Console
    }
}

<#
.SYNOPSIS
Removes the nginx reverse-proxy pod/Service for HolmesGPT from the 'default' namespace.
#>
function Remove-HolmesProxyEndpoints {
    [CmdletBinding()]
    Param()
    Write-Log '[AI-Assistant] Removing HolmesGPT proxy resources from default namespace...' -Console
    (Invoke-Kubectl -Params 'delete', 'deployment',  'holmesgpt-proxy',      '-n', 'default', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'configmap',   'holmesgpt-nginx-conf', '-n', 'default', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'service',     'holmesgpt-holmes',     '-n', 'default', '--ignore-not-found').Output | Write-Log
    # Remove the SSE direct-route ingress
    (Invoke-Kubectl -Params 'delete', 'ingress', 'holmesgpt-sse-direct', '-n', 'ai-assistant', '--ignore-not-found').Output | Write-Log
    # Also clean up legacy resources from older versions
    (Invoke-Kubectl -Params 'delete', 'endpointslice', 'holmesgpt-holmes-k2s', '-n', 'default', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'endpoints',     'holmesgpt-holmes',     '-n', 'default', '--ignore-not-found').Output | Write-Log
}

<#
.SYNOPSIS
Creates the /data/ollama directory on the kubemaster Linux node via SSH.
This directory backs the static PV used by the Ollama models PVC.
Idempotent - safe to call when the directory already exists.
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
Creates (or updates) the 'zscaler-ca' ConfigMap in the ai-assistant namespace
using the ZScaler root CA certificate that is already committed to the K2s repo.
The Ollama init-container mounts this ConfigMap to trust the corporate proxy.
Idempotent - safe to call when the ConfigMap already exists.
#>
function New-ZscalerCaConfigMap {
    [CmdletBinding()]
    Param()

    Write-Log '[AI-Assistant] Creating ZScaler CA ConfigMap for Ollama proxy trust...' -Console

    # Use the cert committed to the K2s repo - no SSH needed
    $certPath = "$PSScriptRoot/../../lib/modules/k2s/k2s.node.module/linuxnode/setup/certificate/ZScalerRootCA.crt"
    $certPath = [System.IO.Path]::GetFullPath($certPath)

    if (-not (Test-Path $certPath)) {
        Write-Log "[AI-Assistant] Warning: ZScaler CA cert not found at '$certPath' - skipping ConfigMap." -Console
        return
    }

    # Strip SPDX header lines (lines starting with #) - keep only the PEM block
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
    Remove-Item $tmpYaml -Force -ErrorAction SilentlyContinue

    Remove-Item $tmpPem -Force -ErrorAction SilentlyContinue
    Write-Log '[AI-Assistant] ZScaler CA ConfigMap ready.' -Console
}



function Invoke-OllamaModelPull {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string] $Model
    )

    Write-Log "[AI-Assistant] Waiting for Ollama pod to be ready..." -Console
    $ollamaReady = Wait-ForPodCondition -Condition Ready -Label 'app=ollama' -Namespace 'ai-assistant' -TimeoutSeconds 180
    if (-not $ollamaReady) {
        throw '[AI-Assistant] Ollama pod did not become ready within 180s'
    }

    # Get the Ollama ClusterIP so we can POST to /api/pull directly from kubemaster.
    # This bypasses the proxy issue: the Ollama *server* correctly uses the system
    # proxy (HTTPS_PROXY in the container) to reach registry.ollama.ai, while our
    # Python client talks to the ClusterIP (cluster-internal, NO_PROXY range).
    $clusterIP = (Invoke-Kubectl -Params 'get', 'svc', 'ollama', '-n', 'ai-assistant',
        '-o', 'jsonpath={.spec.clusterIP}').Output
    if ([string]::IsNullOrWhiteSpace($clusterIP)) {
        throw '[AI-Assistant] Could not resolve ClusterIP for Ollama service'
    }

    Write-Log "[AI-Assistant] Pulling Ollama model '$Model' via REST API at $clusterIP:11434 ..." -Console
    Write-Log "[AI-Assistant] (This may take several minutes - model is ~2 GB)" -Console

    # Write a small Python script to /tmp on kubemaster and run it via SSH.
    # Python is always present on the Debian kubemaster node.
    $pyScript = @"
import urllib.request, json, sys
url = 'http://${clusterIP}:11434/api/pull'
payload = json.dumps({'model': '${Model}', 'stream': True}).encode()
req = urllib.request.Request(url, data=payload,
    headers={'Content-Type': 'application/json'}, method='POST')
try:
    with urllib.request.urlopen(req, timeout=600) as resp:
        for line in resp:
            try:
                d = json.loads(line.decode())
                status = d.get('status', '')
                if 'total' in d and 'completed' in d and d['total']:
                    pct = int(100 * d['completed'] / d['total'])
                    print(f'  {status}: {pct}%', flush=True)
                elif status:
                    print(f'  {status}', flush=True)
            except Exception:
                pass
    print('success', flush=True)
except Exception as e:
    print(f'error: {e}', file=sys.stderr, flush=True)
    sys.exit(1)
"@

    $tmpPy = [System.IO.Path]::GetTempFileName() + '.py'
    $pyScript | Set-Content $tmpPy -Encoding ASCII
    Copy-ToControlPlaneViaSSHKey -Source $tmpPy -Target '/tmp/ollama_pull.py'
    Remove-Item $tmpPy -Force -ErrorAction SilentlyContinue

    $pullResult = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'python3 /tmp/ollama_pull.py' -Timeout 620
    $pullResult.Output | Write-Log
    Remove-Item $tmpPy -Force -ErrorAction SilentlyContinue

    if (-not $pullResult.Success -or ($pullResult.Output -notmatch 'success')) {
        throw "[AI-Assistant] 'ollama pull $Model' failed. See log for details."
    }
    Write-Log "[AI-Assistant] Model '$Model' pulled successfully." -Console
}

<#
.SYNOPSIS
Waits for the HolmesGPT deployment to become available.
#>
function Wait-ForHolmesAvailable {
    return (Wait-ForPodCondition -Condition Ready -Label 'app=holmesgpt' -Namespace 'ai-assistant' -TimeoutSeconds 120)
}

<#
.SYNOPSIS
Removes all ai-assistant addon resources. Optionally keeps the Ollama model PVC.
#>
function Remove-AiAssistantResources {
    [CmdletBinding()]
    Param(
        [switch] $KeepModelData = $false
    )

    # ── HolmesGPT ─────────────────────────────────────────────────────────────
    # Delete the cross-namespace proxy resources first (explicitly, since
    # 'kubectl delete -f' only deletes resources listed in the file - the
    # Endpoints object is created dynamically by Set-HolmesProxyEndpoints).
    Remove-HolmesProxyEndpoints

    Write-Log '[AI-Assistant] Removing HolmesGPT workload resources...' -Console
    (Invoke-Kubectl -Params 'delete', 'deployment',  'holmesgpt-holmes',        '-n', 'ai-assistant', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'service',     'holmesgpt-holmes',        '-n', 'ai-assistant', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'configmap',   'holmesgpt-model-config',  '-n', 'ai-assistant', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'serviceaccount', 'holmesgpt',            '-n', 'ai-assistant', '--ignore-not-found').Output | Write-Log

    # Cluster-scoped RBAC must be deleted explicitly (namespace deletion won't remove them)
    (Invoke-Kubectl -Params 'delete', 'clusterrolebinding', 'holmesgpt-reader', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'clusterrole',        'holmesgpt-reader', '--ignore-not-found').Output | Write-Log

    # ── Ollama ─────────────────────────────────────────────────────────────────
    Write-Log '[AI-Assistant] Removing Ollama resources...' -Console
    (Invoke-Kubectl -Params 'delete', 'deployment',     'ollama', '-n', 'ai-assistant', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'service',        'ollama', '-n', 'ai-assistant', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'serviceaccount', 'ollama', '-n', 'ai-assistant', '--ignore-not-found').Output | Write-Log

    if ($KeepModelData) {
        # Keep PVC and PV (and namespace so the PVC can live in it)
        Write-Log '[AI-Assistant] Ollama PVC/PV preserved - namespace kept for PVC residency.' -Console
    }
    else {
        # Delete PVC then the static PV, then the namespace
        (Invoke-Kubectl -Params 'delete', 'pvc', 'ollama-models', '-n', 'ai-assistant', '--ignore-not-found').Output | Write-Log
        (Invoke-Kubectl -Params 'delete', 'pv', 'ollama-models-pv', '--ignore-not-found').Output | Write-Log
        Write-Log '[AI-Assistant] Deleting ai-assistant namespace...' -Console
        (Invoke-Kubectl -Params 'delete', 'namespace', 'ai-assistant', '--ignore-not-found').Output | Write-Log
    }
}

<#
.SYNOPSIS
Writes post-installation usage notes for the AI Assistant addon.
#>
function Write-AiAssistantUsageForUser {
    [CmdletBinding()]
    Param(
        [string] $Model = 'llama3.2'
    )
    @"

                AI ASSISTANT ADDON - USAGE NOTES

 The AI Assistant addon has deployed:
   - Ollama  (local LLM runtime, namespace: ai-assistant)
   - HolmesGPT (Kubernetes AI agent,  namespace: ai-assistant)
   - AI Assistant Headlamp plugin     (injected into dashboard)

 To use the AI Assistant:
   1. Open the Headlamp dashboard:
      k2s addons status dashboard   (shows the URL / port-forward command)

   2. Click the AI icon in the top-right app bar of Headlamp.

   3. On first use, go to Settings → AI Assistant and configure:
        Provider  : Local Models
        Base URL  : http://ollama.ai-assistant.svc.cluster.local:11434
                    (or use port-forward: kubectl port-forward svc/ollama -n ai-assistant 11434:11434)
        Model     : $Model

   4. Holmes agent:
      The plugin auto-detects HolmesGPT via the K8s service proxy.
      If it shows "disconnected", verify the pod is running:
        kubectl get pods -n ai-assistant -l app=holmesgpt

 To pull an additional Ollama model later:
   kubectl exec -n ai-assistant deployment/ollama -- ollama pull <model-name>

 NOTE: Model files are stored in a PersistentVolumeClaim (ollama-models).
 Disabling the addon with '--keep-model-data' preserves downloaded models.

"@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
}

Export-ModuleMember -Function `
    Get-AiAssistantManifestsDir, Get-OllamaManifestPath, Get-HolmesManifestPath, Get-HolmesSseIngressPath, `
    Set-HolmesModelConfig, Set-HolmesProxyEndpoints, Remove-HolmesProxyEndpoints, `
    New-OllamaDataDirectory, New-ZscalerCaConfigMap, Invoke-OllamaModelPull, `
    Wait-ForHolmesAvailable, Remove-AiAssistantResources, Write-AiAssistantUsageForUser

