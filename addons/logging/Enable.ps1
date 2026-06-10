# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Enables logging addon in the cluster to the logging namespace

.DESCRIPTION
The logging addon collects all logs from containers/pods running inside the k2s cluster.
Logs can be analyzed via opensearch dashboards.

.EXAMPLE
# For k2sSetup
powershell <installation folder>\addons\logging\Enable.ps1
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'External access option')]
    [ValidateSet('nginx', 'nginx-gw', 'traefik', 'none')]
    [string] $Ingress = 'none',
    [parameter(Mandatory = $false, HelpMessage = 'Omit OpenSearch and OpenSearch Dashboards; Fluent-bit uses stdout output')]
    [switch] $OmitOpensearch = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Deploy AI log analysis components (vector index, embedding pipeline, query API)')]
    [switch] $EnableAI = $false,
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$nodeModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.node.module/k2s.node.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$loggingModule = "$PSScriptRoot\logging.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule, $nodeModule, $loggingModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Checking cluster status' -Console

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
    $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon 'logging' can only be enabled for 'k2s' setup type."  
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'logging' })) -eq $true) {
    $errMsg = "Addon 'logging' is already enabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

if ($OmitOpensearch -and $Ingress -ne 'none') {
    Write-Log '--omitOpensearch ignores --ingress (no dashboard to expose); ingress flag will be ignored' -Console
    $Ingress = 'none'
}

if ($OmitOpensearch -and $EnableAI) {
    $errMsg = '--enableAI requires OpenSearch to be running (incompatible with --omitOpensearch).'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

if ($Ingress -ne 'none') {
    Enable-IngressAddon -Ingress:$Ingress
}

(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo mkdir -m 777 -p /logging').Output | Write-Log

# OpenSearch requires vm.max_map_count >= 262144; set it persistently so it survives reboots
(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'echo "vm.max_map_count=262144" | sudo tee /etc/sysctl.d/99-opensearch.conf && sudo sysctl -w vm.max_map_count=262144').Output | Write-Log

$manifestsPath = "$PSScriptRoot\manifests\logging"

function Stop-WithError ([string]$Message) {
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $Message
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    }
    else { Write-Log $Message -Error }
    exit 1
}

function Wait-FluentBitReady {
    Write-Log 'Waiting for Fluent-bit DaemonSets to be ready...' -Console
    $cmd = Invoke-Kubectl -Params 'rollout', 'status', 'daemonset/fluent-bit', '-n', 'logging', '--timeout=300s'
    Write-Log $cmd.Output
    if (!$cmd.Success) { Stop-WithError 'Fluent-bit could not be deployed successfully!' }

    if ($setupInfo.LinuxOnly -eq $false) {
        $cmd = Invoke-Kubectl -Params 'rollout', 'status', 'daemonset/fluent-bit-win', '-n', 'logging', '--timeout=300s'
        Write-Log $cmd.Output
        if (!$cmd.Success) { Stop-WithError 'Fluent-bit Windows could not be deployed successfully!' }
    }
}

if ($OmitOpensearch) {
    Write-Log 'Deploying Fluent-bit only (--omitOpensearch)' -Console

    (Invoke-Kubectl -Params 'apply', '-f', "$manifestsPath\namespace.yaml").Output | Write-Log

    $fluentbitPath = "$manifestsPath\fluentbit"
    (Invoke-Kubectl -Params 'apply', '-f', "$fluentbitPath\clusterrole.yaml").Output | Write-Log
    (Invoke-Kubectl -Params 'apply', '-f', "$fluentbitPath\clusterrolebinding.yaml").Output | Write-Log
    (Invoke-Kubectl -Params 'apply', '-f', "$fluentbitPath\serviceaccount.yaml").Output | Write-Log
    (Invoke-Kubectl -Params 'apply', '-f', "$fluentbitPath\service.yaml").Output | Write-Log
    (Invoke-Kubectl -Params 'apply', '-f', "$fluentbitPath\service-otel.yaml").Output | Write-Log
    (Invoke-Kubectl -Params 'apply', '-f', "$fluentbitPath\stdout\configmap-stdout.yaml").Output | Write-Log
    (Invoke-Kubectl -Params 'apply', '-f', "$fluentbitPath\daemonset.yaml").Output | Write-Log

    if ($setupInfo.LinuxOnly -eq $false) {
        $fluentbitWindowsPath = "$manifestsPath\fluentbit\windows"
        (Invoke-Kubectl -Params 'apply', '-f', "$fluentbitWindowsPath\stdout\configmap-windows-stdout.yaml").Output | Write-Log
        (Invoke-Kubectl -Params 'apply', '-f', "$fluentbitWindowsPath\daemonset-windows.yaml").Output | Write-Log
    }

    Wait-FluentBitReady
}
else {
    Write-Log 'Installing fluent-bit and opensearch stack' -Console

    # opensearch
    # opensearch dashboards
    # fluent-bit linux

    (Invoke-Kubectl -Params 'apply', '-f', "$manifestsPath\namespace.yaml").Output | Write-Log

    $createResult = Invoke-Kubectl -Params 'create', '-k', "$manifestsPath\"
    $createResult.Output | Write-Log
    if (!$createResult.Success) { Stop-WithError "Failed to create logging resources: $($createResult.Output)" }

    # fluent-bit windows
    if ($setupInfo.LinuxOnly -eq $false) {
        $createWinResult = Invoke-Kubectl -Params 'create', '-k', "$manifestsPath\fluentbit\windows"
        $createWinResult.Output | Write-Log
        if (!$createWinResult.Success) { Stop-WithError "Failed to create logging Windows resources: $($createWinResult.Output)" }
    }

    Write-Log 'Waiting for pods being ready...' -Console

    $kubectlCmd = (Invoke-Kubectl -Params 'rollout', 'status', 'statefulsets', '-n', 'logging', '--timeout=900s')
    Write-Log $kubectlCmd.Output
    if (!$kubectlCmd.Success) {
        Write-Log '[Logging] Rollout status timed out - gathering diagnostics' -Console
        (Invoke-Kubectl -Params 'describe', 'pod', '-n', 'logging', '-l', 'app.kubernetes.io/name=opensearch').Output | Write-Log
        (Invoke-Kubectl -Params 'get', 'events', '-n', 'logging', '--sort-by=.lastTimestamp').Output | Write-Log
        Stop-WithError 'Opensearch could not be deployed successfully!'
    }

    $kubectlCmd = (Invoke-Kubectl -Params 'rollout', 'status', 'deployments', '-n', 'logging', '--timeout=600s')
    Write-Log $kubectlCmd.Output
    if (!$kubectlCmd.Success) {
        Write-Log '[Logging] Deployment rollout failed - gathering diagnostics' -Console
        (Invoke-Kubectl -Params 'describe', 'pod', '-n', 'logging', '-l', 'app.kubernetes.io/name=opensearch-dashboards').Output | Write-Log
        (Invoke-Kubectl -Params 'get', 'events', '-n', 'logging', '--sort-by=.lastTimestamp').Output | Write-Log
        Stop-WithError 'Opensearch dashboards could not be deployed successfully!'
    }

    Wait-FluentBitReady

    # Import saved objects 
    $dashboardIP = (Invoke-Kubectl -Params 'get', 'pods', '-l=app.kubernetes.io/name=opensearch-dashboards', '-n', 'logging', '-o=jsonpath="{.items[0].status.podIP}"').Output
    $dashboardIP = $dashboardIP -replace '"', ''

    $importingSavedObjects = curl.exe -X POST --retry 10 --retry-delay 5 --silent --disable --fail --retry-all-errors "http://${dashboardIP}:5601/logging/api/saved_objects/_import?overwrite=true" -H 'osd-xsrf: true' -F "file=@$PSScriptRoot/opensearch-dashboard-saved-objects/k2s-index-pattern.ndjson" 2>$null
    Write-Log $importingSavedObjects

    if ($EnableAI) {
        Write-Log '[AI] Deploying AI log analysis components (vector index, embedding pipeline, query API)' -Console
        Write-Log '[AI] Using Windows-host Ollama from the ai-assistant addon (bridge endpoint 172.19.1.1:11434).' -Console
        Write-Log '[AI] Verifying Windows-host Ollama and nomic-embed-text model availability...' -Console

        $tagsJson = ''
        $ollamaReachable = $false
        try {
            $tagsJson = & curl.exe -s http://localhost:11434/api/tags --max-time 10 2>&1
            $ollamaReachable = ($LASTEXITCODE -eq 0 -and $tagsJson -match '"models"')
        }
        catch {
            $ollamaReachable = $false
        }

        if (-not $ollamaReachable) {
            Write-Log '[AI] Warning: Windows-host Ollama is not reachable at http://localhost:11434. Start or repair the ai-assistant addon before using semantic search.' -Console
        }
        elseif ($tagsJson -notmatch 'nomic-embed-text') {
            $ollamaCli = Get-Command 'ollama.exe' -ErrorAction SilentlyContinue
            if ($null -eq $ollamaCli) {
                Write-Log '[AI] Warning: nomic-embed-text is not loaded and ollama.exe is not available on PATH. Run: ollama pull nomic-embed-text' -Console
            }
            else {
                Write-Log '[AI] Pulling nomic-embed-text on the Windows host...' -Console
                $pullOutput = & $ollamaCli.Source pull nomic-embed-text 2>&1
                $pullOutput | Write-Log
                if ($LASTEXITCODE -ne 0) {
                    Write-Log '[AI] Warning: nomic-embed-text pull failed on the Windows host. Semantic search may fail until the model is available.' -Console
                }
            }
        }
        else {
            Write-Log '[AI] nomic-embed-text is already available on the Windows-host Ollama service.' -Console
        }

        $aiManifestsPath = "$manifestsPath\ai"
        $aiSourcePath = "$PSScriptRoot\ai"


        # Create source ConfigMaps from actual Python files so containers have the app code.
        # logging-ai-src-root: main.py
        # logging-ai-src-app:  app/*.py  (all module files)
        Write-Log '[AI] Creating source ConfigMaps from Python source files...' -Console

        $tmpDir = [System.IO.Path]::GetTempPath()
        $srcRootTmp = Join-Path $tmpDir 'logging-ai-src-root.yaml'
        $srcAppTmp  = Join-Path $tmpDir 'logging-ai-src-app.yaml'

        $srcRootArgs = @(
            'create', 'configmap', 'logging-ai-src-root',
            "--from-file=main.py=$aiSourcePath\main.py",
            '-n', 'logging',
            '--dry-run=client', '-o', 'yaml'
        )
        $result = Invoke-Kubectl -Params $srcRootArgs
        if ($result.Success) {
            $result.Output | Set-Content -Path $srcRootTmp -Encoding utf8
            (Invoke-Kubectl -Params @('apply', '-f', $srcRootTmp)).Output | Write-Log
        } else {
            Write-Log "[AI] Warning: Failed to generate logging-ai-src-root ConfigMap: $($result.Output)" -Console
        }

        $appFiles = Get-ChildItem "$aiSourcePath\app\*.py" | ForEach-Object { "--from-file=$($_.Name)=$($_.FullName)" }
        $srcAppArgs = @('create', 'configmap', 'logging-ai-src-app', '-n', 'logging', '--dry-run=client', '-o', 'yaml') + $appFiles
        $result = Invoke-Kubectl -Params $srcAppArgs
        if ($result.Success) {
            $result.Output | Set-Content -Path $srcAppTmp -Encoding utf8
            (Invoke-Kubectl -Params @('apply', '-f', $srcAppTmp)).Output | Write-Log
        } else {
            Write-Log "[AI] Warning: Failed to generate logging-ai-src-app ConfigMap: $($result.Output)" -Console
        }

        Write-Log '[AI] Source ConfigMaps ready.' -Console
        (Invoke-Kubectl -Params @('apply', '-k', "$aiManifestsPath\")).Output | Write-Log

        # Deploy demo broken pod in its own namespace (outside kustomize so namespace override doesn't apply)
        Write-Log '[AI] Deploying demo error-prone order-service pod for log analysis demo...' -Console
        (Invoke-Kubectl -Params @('apply', '-f', "$aiManifestsPath\demo-broken-pod.yaml")).Output | Write-Log

        Write-Log '[AI] Waiting for AI query API deployment...' -Console
        $kubectlCmd = (Invoke-Kubectl -Params @('rollout', 'status', 'deployment', 'logging-ai-api', '-n', 'logging', '--timeout=300s'))
        Write-Log $kubectlCmd.Output
        if (!$kubectlCmd.Success) {
            Write-Log '[AI] Warning: AI query API deployment did not become ready in time. Check pod logs for details.' -Console
        }
        else {
            Write-Log '[AI] AI components deployed successfully.' -Console

            # Run the embedding pipeline immediately so the vector index is populated on first enable.
            # Without this, users would have to wait up to an hour for the CronJob to fire.
            Write-Log '[AI] Running initial embedding pipeline to index existing logs (this may take ~30s)...' -Console
            $jobName = "pipeline-initial-$(Get-Date -Format 'yyyyMMddHHmmss')"
            $jobResult = Invoke-Kubectl -Params @('create', 'job', '--from=cronjob/logging-ai-pipeline', $jobName, '-n', 'logging')
            $jobResult.Output | Write-Log
            if ($jobResult.Success) {
                $kubectlCmd = Invoke-Kubectl -Params @('wait', '--for=condition=complete', "job/$jobName", '-n', 'logging', '--timeout=120s')
                Write-Log $kubectlCmd.Output
                if ($kubectlCmd.Success) {
                    Write-Log '[AI] Initial pipeline run complete — vector index is populated and ready for semantic search.' -Console
                } else {
                    Write-Log '[AI] Warning: Pipeline job did not complete within 120s. Check: kubectl logs -n logging job/' + $jobName -Console
                }
            } else {
                Write-Log '[AI] Warning: Could not create initial pipeline job. Run manually: kubectl create job --from=cronjob/logging-ai-pipeline pipeline-run -n logging' -Console
            }

            Write-Log '[AI] To start semantic search, open the demo UI:' -Console
            Write-Log '[AI]   1. Run: kubectl -n logging port-forward svc/logging-ai-api 9090:9090' -Console
            Write-Log "[AI]   2. Open: $PSScriptRoot\ai\demo.html" -Console
        }
    }

    &"$PSScriptRoot\Update.ps1"
}

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'logging'; OmitOpensearch = $OmitOpensearch.IsPresent; EnableAI = $EnableAI.IsPresent })
Write-Log 'Logging Stack installed successfully'

if (-not $OmitOpensearch) {
    Write-UsageForUser
    Write-BrowserWarningForUser
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}