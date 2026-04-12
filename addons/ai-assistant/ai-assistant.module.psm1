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
Deploys a Python-based smart proxy pod + selector-based Service in the 'default'
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
'default' that relays traffic to 'ai-assistant'.

The proxy is implemented in Python (python:alpine image) so it can:
  1. Intercept POST /api/agui/chat requests and inject the strict system prompt
     into the 'additional_system_prompt' field of the JSON body — controlling
     Holmes behaviour without modifying the Headlamp plugin or the Holmes image.
  2. Filter empty SSE delta chunks that cause pydantic validation errors in the
     plugin (TextMessageContentEvent: 'delta' must have at least 1 character).

Architecture:
  Headlamp plugin
    → K8s apiserver proxy (/namespaces/default/services/holmesgpt-holmes:80/proxy/...)
    → Python proxy pod in 'default' (selector: app=holmesgpt-proxy)
    → holmesgpt-holmes.ai-assistant.svc.cluster.local:80
    → HolmesGPT pod in 'ai-assistant'
#>
function Set-HolmesProxyEndpoints {
    [CmdletBinding()]
    Param()

    Write-Log '[AI-Assistant] Deploying HolmesGPT smart proxy in default namespace...' -Console

    # Clean up legacy resources from older versions
    (Invoke-Kubectl -Params 'delete', 'endpointslice', 'holmesgpt-holmes-k2s', '-n', 'default', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'endpoints',     'holmesgpt-holmes',     '-n', 'default', '--ignore-not-found').Output | Write-Log
    # Remove old nginx ConfigMap from previous versions
    (Invoke-Kubectl -Params 'delete', 'configmap', 'holmesgpt-nginx-conf', '-n', 'default', '--ignore-not-found').Output | Write-Log

    # ── Strict system prompt injected into every Holmes chat request ──────────
    # This constrains Holmes to deterministic, single-tool-call behaviour:
    #   - No autonomous multi-step planning (no TodoWrite)
    #   - No chaining multiple tool calls in one response
    #   - Return ONLY the tool result, no extra commentary
    #   - Never send empty text chunks (prevents pydantic validation errors)
    $strictSystemPrompt = @'
STRICT CONTROLLED ASSISTANT MODE — APPLY GLOBALLY.

PRIMARY OBJECTIVE: For every user request, execute exactly ONE relevant tool call, return ONLY the final result, then STOP.

EXECUTION RULES (MANDATORY):

Rule 1 — Single Tool Call Only:
- Call AT MOST ONE tool per user request.
- Do NOT chain multiple tool calls.
- Do NOT retry automatically.
- If the first tool result is insufficient → return it as-is.

Rule 2 — No Autonomous Behavior. You MUST NOT:
- Use TodoWrite.
- Create tasks, to-do lists, or investigation plans.
- Suggest next steps unprompted.
- Continue execution after answering.

Rule 3 — No Reasoning Output. Do NOT output:
- Thought process or internal reasoning.
- Analysis beyond the direct answer.
- Debug explanations.

Rule 4 — Output Format:
- If tool returns tabular/list data: return ONLY the clean result table.
- If tool returns structured data: convert to simple readable format (no raw JSON unless necessary).
- NEVER return raw JSON tool instructions or internal schemas.
- NEVER return duplicate responses.
- ALWAYS ensure output is non-empty; never send empty text chunks.

Rule 5 — Accuracy:
- Use ONLY tool output. Do NOT infer missing data. Do NOT guess.
- If tool result is empty → return exactly: No data found
- If tool fails → return exactly: Unable to determine from available data

Rule 6 — No Re-execution: Do NOT call the tool again. Do NOT refine the query.

Rule 7 — No Context Carryover: Treat each query independently.

Rule 8 — Streaming Safety: Final response MUST contain valid non-empty text.

FORBIDDEN: TodoWrite, multi-step reasoning, auto-debugging, cluster-wide analysis, recommendations, follow-up questions.
'@

    # ── Python proxy script ───────────────────────────────────────────────────
    # Reads HOLMES_BACKEND_URL from env (set in the Deployment).
    # For POST /api/agui/chat: injects additional_system_prompt into the JSON body.
    # For SSE responses: filters lines where data.delta == "" to prevent pydantic errors.
    # All other paths: transparent proxy.
    $proxyScript = @'
#!/usr/bin/env python3
"""
HolmesGPT strict-mode proxy.
Injects additional_system_prompt into every POST /api/agui/chat request so that
Holmes operates in deterministic single-tool-call mode regardless of what the
Headlamp plugin sends.  Also strips empty SSE delta chunks that cause pydantic
validation errors (TextMessageContentEvent: delta must have >= 1 character).
"""
import json
import logging
import os
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.error import URLError
from urllib.request import Request, urlopen

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s proxy %(levelname)s %(message)s",
    stream=sys.stdout,
)

BACKEND = os.environ.get(
    "HOLMES_BACKEND_URL",
    "http://holmesgpt-holmes.ai-assistant.svc.cluster.local:80",
).rstrip("/")

SYSTEM_PROMPT_FILE = os.environ.get(
    "HOLMES_STRICT_PROMPT_FILE", "/etc/holmes-proxy/strict_system_prompt.txt"
)

try:
    with open(SYSTEM_PROMPT_FILE, "r", encoding="utf-8") as _f:
        STRICT_PROMPT = _f.read().strip()
    logging.info("Loaded strict system prompt (%d chars)", len(STRICT_PROMPT))
except OSError as _e:
    logging.warning("Could not load strict system prompt from %s: %s", SYSTEM_PROMPT_FILE, _e)
    STRICT_PROMPT = ""

CHAT_PATH_RE = re.compile(r"^/api/agui/chat(/.*)?$")


def _is_chat_endpoint(path: str) -> bool:
    return bool(CHAT_PATH_RE.match(path.split("?")[0]))


def _inject_prompt(body_bytes: bytes) -> bytes:
    """Inject STRICT_PROMPT into the additional_system_prompt field."""
    if not STRICT_PROMPT:
        return body_bytes
    try:
        data = json.loads(body_bytes.decode("utf-8"))
        existing = data.get("additional_system_prompt") or ""
        if existing:
            data["additional_system_prompt"] = STRICT_PROMPT + "\n\n" + existing
        else:
            data["additional_system_prompt"] = STRICT_PROMPT
        return json.dumps(data).encode("utf-8")
    except Exception as exc:
        logging.warning("Could not inject system prompt: %s", exc)
        return body_bytes


def _filter_sse_line(line: bytes) -> bytes | None:
    """
    Return the line unchanged, or None to drop it.
    Drops SSE data lines where the JSON delta field is an empty string —
    these cause pydantic validation errors in the Headlamp plugin.
    """
    if not line.startswith(b"data:"):
        return line
    payload = line[5:].strip()
    if not payload or payload == b"[DONE]":
        return line
    try:
        obj = json.loads(payload)
        # TextMessageContentEvent / similar: drop if delta is empty string
        if obj.get("type") in ("TEXT_MESSAGE_CONTENT", "text_message_content"):
            delta = obj.get("delta", None)
            if delta is not None and isinstance(delta, str) and len(delta) == 0:
                return None
    except Exception:
        pass
    return line


class ProxyHandler(BaseHTTPRequestHandler):
    server_version = "HolmesProxy/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # noqa: N802
        logging.info("%-4s %s", self.command, self.path)

    def _forward(self, body: bytes | None = None):
        target = BACKEND + self.path
        headers = {
            k: v
            for k, v in self.headers.items()
            if k.lower() not in ("host", "content-length", "transfer-encoding")
        }
        if body is not None:
            headers["Content-Length"] = str(len(body))

        req = Request(target, data=body, headers=headers, method=self.command)
        try:
            resp = urlopen(req, timeout=620)
        except URLError as exc:
            logging.error("Backend error: %s", exc)
            self.send_response(502)
            self.end_headers()
            return

        self.send_response(resp.status)
        is_sse = False
        for k, v in resp.headers.items():
            if k.lower() == "transfer-encoding":
                continue
            if k.lower() == "content-type" and "text/event-stream" in v:
                is_sse = True
            self.send_header(k, v)

        if is_sse:
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            try:
                for raw_line in resp:
                    filtered = _filter_sse_line(raw_line.rstrip(b"\r\n"))
                    if filtered is None:
                        continue
                    line = filtered + b"\n"
                    hex_len = format(len(line), "x").encode() + b"\r\n"
                    self.wfile.write(hex_len + line + b"\r\n")
                    self.wfile.flush()
                # Final chunk
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            except Exception as exc:
                logging.warning("SSE stream interrupted: %s", exc)
        else:
            resp_body = resp.read()
            self.send_header("Content-Length", str(len(resp_body)))
            self.end_headers()
            self.wfile.write(resp_body)

    def do_GET(self):  # noqa: N802
        self._forward()

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""
        if _is_chat_endpoint(self.path):
            body = _inject_prompt(body)
        self._forward(body)

    def do_DELETE(self):  # noqa: N802
        self._forward()

    def do_PUT(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""
        self._forward(body)

    def do_PATCH(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""
        self._forward(body)


class ThreadingHTTPServer(HTTPServer):
    def process_request(self, request, client_address):
        t = threading.Thread(target=self._handle, args=(request, client_address))
        t.daemon = True
        t.start()

    def _handle(self, request, client_address):
        try:
            self.finish_request(request, client_address)
        except Exception:
            self.handle_error(request, client_address)
        finally:
            self.shutdown_request(request)


if __name__ == "__main__":
    port = int(os.environ.get("PROXY_PORT", 80))
    logging.info("HolmesGPT proxy listening on :%d → %s", port, BACKEND)
    srv = ThreadingHTTPServer(("0.0.0.0", port), ProxyHandler)
    srv.serve_forever()
'@

    # Write the strict system prompt to a temp file, then create a ConfigMap
    $tmpPrompt = [System.IO.Path]::GetTempFileName() + '.txt'
    [System.IO.File]::WriteAllText($tmpPrompt, $strictSystemPrompt, [System.Text.Encoding]::UTF8)
    $tmpScript = [System.IO.Path]::GetTempFileName() + '.py'
    [System.IO.File]::WriteAllText($tmpScript, $proxyScript, [System.Text.Encoding]::ASCII)

    $cmResult = Invoke-Kubectl -Params 'create', 'configmap', 'holmesgpt-proxy-config',
        '-n', 'default',
        "--from-file=strict_system_prompt.txt=$tmpPrompt",
        "--from-file=proxy.py=$tmpScript",
        '--dry-run=client', '-o', 'yaml'
    $tmpYaml = [System.IO.Path]::GetTempFileName() + '.yaml'
    $cmResult.Output | Set-Content $tmpYaml -Encoding UTF8
    (Invoke-Kubectl -Params 'apply', '-f', $tmpYaml).Output | Write-Log
    Remove-Item $tmpYaml, $tmpPrompt, $tmpScript -Force -ErrorAction SilentlyContinue

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
        - name: proxy
          image: python:3.11-alpine
          imagePullPolicy: IfNotPresent
          command: ["python3", "/etc/holmes-proxy/proxy.py"]
          ports:
            - containerPort: 80
          env:
            - name: HOLMES_BACKEND_URL
              value: "http://holmesgpt-holmes.ai-assistant.svc.cluster.local:80"
            - name: HOLMES_STRICT_PROMPT_FILE
              value: "/etc/holmes-proxy/strict_system_prompt.txt"
            - name: PROXY_PORT
              value: "80"
          volumeMounts:
            - name: proxy-config
              mountPath: /etc/holmes-proxy
              readOnly: true
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              cpu: 200m
              memory: 128Mi
      volumes:
        - name: proxy-config
          configMap:
            name: holmesgpt-proxy-config
            defaultMode: 0755
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
    $ready = Wait-ForPodCondition -Condition Ready -Label 'app=holmesgpt-proxy' -Namespace 'default' -TimeoutSeconds 90
    if (-not $ready) {
        Write-Log '[AI-Assistant] Warning: HolmesGPT proxy pod did not become ready within 90s. Check: kubectl get pods -n default -l app=holmesgpt-proxy' -Console
    } else {
        Write-Log '[AI-Assistant] HolmesGPT smart proxy is ready.' -Console
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
Removes the Python smart proxy pod/Service for HolmesGPT from the 'default' namespace.
#>
function Remove-HolmesProxyEndpoints {
    [CmdletBinding()]
    Param()
    Write-Log '[AI-Assistant] Removing HolmesGPT proxy resources from default namespace...' -Console
    (Invoke-Kubectl -Params 'delete', 'deployment',  'holmesgpt-proxy',       '-n', 'default', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'configmap',   'holmesgpt-proxy-config','-n', 'default', '--ignore-not-found').Output | Write-Log
    # Also remove legacy nginx ConfigMap from older versions
    (Invoke-Kubectl -Params 'delete', 'configmap',   'holmesgpt-nginx-conf',  '-n', 'default', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'service',     'holmesgpt-holmes',      '-n', 'default', '--ignore-not-found').Output | Write-Log
    # Remove the SSE direct-route ingress and the bridge service
    (Invoke-Kubectl -Params 'delete', 'ingress', 'holmesgpt-sse-direct',    '-n', 'ai-assistant', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'service', 'holmesgpt-proxy-bridge',  '-n', 'ai-assistant', '--ignore-not-found').Output | Write-Log
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

