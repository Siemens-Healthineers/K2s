# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule

$script:KagentNamespace = 'kagent'
$script:KagentCrdsRelease = 'kagent-crds'
$script:KagentRelease = 'kagent'

function Get-KagentChartDirectory {
    return "$PSScriptRoot\manifests\chart"
}

function Get-KagentCrdsChartPath {
    $chartDir = Get-KagentChartDirectory
    $charts = @(Get-ChildItem -Path $chartDir -Filter 'kagent-crds-*.tgz' -ErrorAction SilentlyContinue)
    if ($charts.Count -eq 0) {
        return $null
    }
    return $charts[0].FullName
}

function Get-KagentChartPath {
    $chartDir = Get-KagentChartDirectory
    $charts = @(Get-ChildItem -Path $chartDir -Filter 'kagent-*.tgz' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^kagent-crds-' })
    if ($charts.Count -eq 0) {
        return $null
    }
    return $charts[0].FullName
}

function New-KagentApiKeySecret {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Provider,
        [Parameter(Mandatory = $true)]
        [string] $ApiKey
    )

    $secretName = switch ($Provider) {
        'openAI' { 'kagent-openai' }
        'anthropic' { 'kagent-anthropic' }
        default { throw "[Kagent] Unknown provider '$Provider' for secret creation" }
    }

    $keyName = switch ($Provider) {
        'openAI' { 'OPENAI_API_KEY' }
        'anthropic' { 'ANTHROPIC_API_KEY' }
    }

    Write-Log "[Kagent] Creating Kubernetes secret '$secretName' in namespace '$script:KagentNamespace'" -Console

    # Delete existing secret if present (idempotent)
    (Invoke-Kubectl -Params 'delete', 'secret', $secretName, '-n', $script:KagentNamespace, '--ignore-not-found').Output | Write-Log

    $result = Invoke-Kubectl -Params 'create', 'secret', 'generic', $secretName, `
        '-n', $script:KagentNamespace, `
        "--from-literal=$keyName=$ApiKey"

    if (-not $result.Success) {
        throw "[Kagent] Failed to create API key secret: $($result.Output)"
    }

    $result.Output | Write-Log
}

function Install-LocalPathProvisioner {
    # Check if StorageClass already exists (idempotent)
    $scExists = (Invoke-Kubectl -Params 'get', 'storageclass', 'local-path', '--ignore-not-found').Output
    if ($scExists) {
        Write-Log '[Kagent] StorageClass local-path already exists; skipping provisioner install' -Console
        return
    }

    $manifestPath = "$PSScriptRoot\manifests\local-path-provisioner.yaml"
    if (-not (Test-Path $manifestPath)) {
        throw "[Kagent] local-path-provisioner manifest not found at '$manifestPath'"
    }

    Write-Log '[Kagent] Installing local-path-provisioner for persistent storage' -Console
    $result = Invoke-Kubectl -Params 'apply', '-f', $manifestPath
    if (-not $result.Success) {
        throw "[Kagent] Failed to install local-path-provisioner: $($result.Output)"
    }
    $result.Output | Write-Log

    # Wait for the provisioner pod to be ready
    $podReady = Wait-ForPodCondition -Condition Ready -Label 'app=local-path-provisioner' -Namespace 'local-path-storage' -TimeoutSeconds 120
    if ($podReady -ne $true) {
        Write-Log '[Kagent] Warning: local-path-provisioner pod did not become ready within timeout' -Console
    }
}

function Uninstall-LocalPathProvisioner {
    $scExists = (Invoke-Kubectl -Params 'get', 'storageclass', 'local-path', '--ignore-not-found').Output
    if (-not $scExists) {
        Write-Log '[Kagent] local-path-provisioner not found; skipping removal' -Console
        return
    }

    $manifestPath = "$PSScriptRoot\manifests\local-path-provisioner.yaml"
    if (Test-Path $manifestPath) {
        Write-Log '[Kagent] Removing local-path-provisioner' -Console
        $result = Invoke-Kubectl -Params 'delete', '-f', $manifestPath, '--ignore-not-found'
        $result.Output | Write-Log
    }
    else {
        # Fallback: delete resources individually
        Write-Log '[Kagent] Removing local-path-provisioner resources individually' -Console
        (Invoke-Kubectl -Params 'delete', 'storageclass', 'local-path', '--ignore-not-found').Output | Write-Log
        (Invoke-Kubectl -Params 'delete', 'namespace', 'local-path-storage', '--ignore-not-found').Output | Write-Log
        (Invoke-Kubectl -Params 'delete', 'clusterrole', 'local-path-provisioner-role', '--ignore-not-found').Output | Write-Log
        (Invoke-Kubectl -Params 'delete', 'clusterrolebinding', 'local-path-provisioner-bind', '--ignore-not-found').Output | Write-Log
    }
}

function Install-KagentViaHelm {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Provider,
        [Parameter(Mandatory = $false)]
        [string] $ApiKey = ''
    )

    $crdsChartPath = Get-KagentCrdsChartPath
    if ($null -eq $crdsChartPath) {
        throw '[Kagent] No kagent-crds Helm chart .tgz found in manifests/chart/'
    }

    $chartPath = Get-KagentChartPath
    if ($null -eq $chartPath) {
        throw '[Kagent] No kagent Helm chart .tgz found in manifests/chart/'
    }

    $chartDir = Get-KagentChartDirectory
    $valuesPath = Join-Path $chartDir 'values.yaml'
    if (-not (Test-Path $valuesPath)) {
        throw "[Kagent] values.yaml not found at '$valuesPath'"
    }

    # Ensure namespace exists
    $nsExists = (Invoke-Kubectl -Params 'get', 'namespace', $script:KagentNamespace, '--ignore-not-found').Output
    if (-not $nsExists) {
        Write-Log "[Kagent] Creating namespace '$script:KagentNamespace'" -Console
        (Invoke-Kubectl -Params 'create', 'namespace', $script:KagentNamespace).Output | Write-Log
    }

    # Install local-path-provisioner (required for PostgreSQL PVC)
    Install-LocalPathProvisioner

    # Create API key secret for providers that need one
    if ($Provider -notin @('none', 'ollama') -and $ApiKey) {
        New-KagentApiKeySecret -Provider $Provider -ApiKey $ApiKey
    }

    # Step 1: Install CRDs chart
    Write-Log "[Kagent] Installing CRDs via Helm chart: $(Split-Path $crdsChartPath -Leaf)" -Console
    $crdsResult = Invoke-Helm -Params @(
        'upgrade', '--install', $script:KagentCrdsRelease, $crdsChartPath,
        '--namespace', $script:KagentNamespace,
        '--wait', '--timeout', '2m0s'
    )
    $crdsResult.Output | Write-Log
    if (-not $crdsResult.Success) {
        throw "[Kagent] helm install kagent-crds failed. See log for details."
    }

    # Wait for CRDs to be established
    Write-Log '[Kagent] Waiting for CRDs to be established' -Console
    $crdNames = @('agents.kagent.dev', 'modelconfigs.kagent.dev', 'toolservers.kagent.dev')
    foreach ($crd in $crdNames) {
        $crdResult = Invoke-Kubectl -Params 'wait', '--for=condition=Established', "crd/$crd", '--timeout=60s'
        if (-not $crdResult.Success) {
            Write-Log "[Kagent] Warning: CRD '$crd' may not be established yet: $($crdResult.Output)" -Console
        }
    }

    # Step 2: Install main kagent chart
    Write-Log "[Kagent] Installing Kagent via Helm chart: $(Split-Path $chartPath -Leaf)" -Console
    $helmParams = @(
        'upgrade', '--install', $script:KagentRelease, $chartPath,
        '--namespace', $script:KagentNamespace,
        '--values', $valuesPath,
        '--wait', '--timeout', '5m0s'
    )

    # Only set a provider if the user explicitly chose one
    if ($Provider -ne 'none') {
        $helmParams += '--set'
        $helmParams += "providers.default=$Provider"
    }

    $helmResult = Invoke-Helm -Params $helmParams
    $helmResult.Output | Write-Log
    if (-not $helmResult.Success) {
        throw '[Kagent] helm install kagent failed. See log for details.'
    }
}

function Uninstall-KagentViaHelm {
    # Uninstall main chart first
    $releaseExists = (Invoke-Helm -Params @('list', '-n', $script:KagentNamespace, '-q')).Output
    if ($releaseExists -match $script:KagentRelease) {
        Write-Log '[Kagent] Uninstalling Kagent Helm release' -Console
        $helmResult = Invoke-Helm -Params @('uninstall', $script:KagentRelease, '--namespace', $script:KagentNamespace, '--wait', '--timeout', '2m0s')
        $helmResult.Output | Write-Log
        if (-not $helmResult.Success) {
            Write-Log '[Kagent] Warning: helm uninstall kagent returned non-zero; continuing cleanup' -Console
        }
    }
    else {
        Write-Log '[Kagent] No kagent Helm release found; skipping helm uninstall' -Console
    }

    # NOTE: CRDs are intentionally NOT removed on disable.
    # Removing CRDs deletes all custom resources across all namespaces.
    # Users can manually remove them with: helm uninstall kagent-crds -n kagent
    if ($releaseExists -match $script:KagentCrdsRelease) {
        Write-Log '[Kagent] CRDs chart is left in place (removing CRDs would delete all kagent resources)' -Console
        Write-Log "[Kagent] To fully remove CRDs, run: helm uninstall $($script:KagentCrdsRelease) -n $($script:KagentNamespace)" -Console
    }

    # Remove local-path-provisioner (installed for PostgreSQL PVC)
    Uninstall-LocalPathProvisioner
}

function Wait-ForKagentAvailable {
    $controllerReady = Wait-ForPodCondition -Condition Ready -Label 'app.kubernetes.io/name=kagent,app.kubernetes.io/component=controller' -Namespace $script:KagentNamespace -TimeoutSeconds 300
    if ($controllerReady -ne $true) {
        Write-Log '[Kagent] Controller pods did not become ready' -Console
        return $false
    }

    $uiReady = Wait-ForPodCondition -Condition Ready -Label 'app.kubernetes.io/name=kagent,app.kubernetes.io/component=ui' -Namespace $script:KagentNamespace -TimeoutSeconds 120
    if ($uiReady -ne $true) {
        Write-Log '[Kagent] UI pods did not become ready' -Console
        return $false
    }

    return $true
}

function Write-KagentUsageForUser {
    @"
                KAGENT ADDON - USAGE NOTES
 Kagent is a Kubernetes-native AI agent framework.

 ACCESSING THE KAGENT UI:
 Use port-forwarding to the kagent UI service:
   kubectl port-forward svc/kagent-ui -n kagent 8080:8080
 Then open: http://localhost:8080

 USING KAGENT AGENTS FROM MCP CLIENTS (Copilot CLI, Cursor, Claude Code):
 1. Port-forward the controller:
      kubectl port-forward svc/kagent-controller -n kagent 8083:8083
 2. Add MCP server to your client config with URL: http://localhost:8083/mcp
 3. The MCP server exposes 'list_agents' and 'invoke_agent' tools.

 See the addon README for detailed MCP client configuration examples.
 Read more: https://kagent.dev/docs/kagent/getting-started/quickstart
"@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
}

function Deploy-CopilotCliAgent {
    $secretName = 'copilot-github-token'
    $sourceNamespace = 'default'

    # Check if the secret exists in the source namespace
    $secretExists = (Invoke-Kubectl -Params 'get', 'secret', $secretName, '-n', $sourceNamespace, '--ignore-not-found').Output
    if (-not $secretExists) {
        Write-Log "[Kagent] WARNING: Secret '$secretName' not found in namespace '$sourceNamespace'." -Console
        Write-Log "[Kagent] The Copilot CLI pod will not start until you create it:" -Console
        Write-Log "[Kagent]   kubectl create secret generic $secretName -n $sourceNamespace --from-literal=GITHUB_TOKEN=<your-fine-grained-pat>" -Console
        Write-Log "[Kagent] The PAT must have the 'Copilot Requests' permission enabled." -Console
    }
    else {
        Write-Log "[Kagent] Found secret '$secretName' in namespace '$sourceNamespace'" -Console

        # Copy the secret into the kagent namespace so the pod can reference it
        $existsInKagent = (Invoke-Kubectl -Params 'get', 'secret', $secretName, '-n', $script:KagentNamespace, '--ignore-not-found').Output
        if (-not $existsInKagent) {
            Write-Log "[Kagent] Copying secret '$secretName' into namespace '$($script:KagentNamespace)'" -Console
            $tokenValue = (Invoke-Kubectl -Params 'get', 'secret', $secretName, '-n', $sourceNamespace, '-o', 'jsonpath={.data.GITHUB_TOKEN}').Output
            $result = Invoke-Kubectl -Params 'create', 'secret', 'generic', $secretName, `
                '-n', $script:KagentNamespace, `
                "--from-literal=GITHUB_TOKEN=$([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($tokenValue)))"
            if (-not $result.Success) {
                Write-Log "[Kagent] Warning: Failed to copy secret: $($result.Output)" -Console
            }
        }
    }

    # Apply the BYO Agent CR manifest
    $manifestPath = "$PSScriptRoot\manifests\copilot-cli-agent.yaml"
    if (-not (Test-Path $manifestPath)) {
        throw "[Kagent] Copilot CLI agent manifest not found at '$manifestPath'"
    }

    Write-Log '[Kagent] Applying Copilot CLI BYO agent manifest' -Console
    $applyResult = Invoke-Kubectl -Params 'apply', '-f', $manifestPath
    if (-not $applyResult.Success) {
        throw "[Kagent] Failed to apply Copilot CLI agent manifest: $($applyResult.Output)"
    }
    $applyResult.Output | Write-Log

    # Grant cluster-wide read access so Copilot CLI can run kubectl commands
    $bindingExists = (Invoke-Kubectl -Params 'get', 'clusterrolebinding', 'copilot-cli-view', '--ignore-not-found').Output
    if (-not $bindingExists) {
        Write-Log '[Kagent] Binding view ClusterRole to copilot-cli ServiceAccount' -Console
        $rbacResult = Invoke-Kubectl -Params 'create', 'clusterrolebinding', 'copilot-cli-view', `
            '--clusterrole=view', `
            "--serviceaccount=$($script:KagentNamespace):copilot-cli"
        if (-not $rbacResult.Success) {
            Write-Log "[Kagent] Warning: Failed to create ClusterRoleBinding: $($rbacResult.Output)" -Console
        }
    }

    Write-Log '[Kagent] Copilot CLI BYO agent deployed successfully' -Console
}

function Remove-CopilotCliAgent {
    # Check if the Copilot CLI agent CR exists before attempting removal
    $agentExists = (Invoke-Kubectl -Params 'get', 'agent', 'copilot-cli', '-n', $script:KagentNamespace, '--ignore-not-found').Output
    if ($agentExists) {
        Write-Log '[Kagent] Removing Copilot CLI BYO agent' -Console
        (Invoke-Kubectl -Params 'delete', 'agent', 'copilot-cli', '-n', $script:KagentNamespace, '--ignore-not-found').Output | Write-Log
        # NOTE: The 'copilot-github-token' secret is intentionally NOT deleted.
        # It is user-created and contains a personal access token that should
        # survive disable/re-enable cycles.
    }

    # Remove the view ClusterRoleBinding
    (Invoke-Kubectl -Params 'delete', 'clusterrolebinding', 'copilot-cli-view', '--ignore-not-found').Output | Write-Log
}

Export-ModuleMember -Function Get-KagentChartDirectory, Get-KagentChartPath, Get-KagentCrdsChartPath, Install-LocalPathProvisioner, Uninstall-LocalPathProvisioner, Install-KagentViaHelm, Uninstall-KagentViaHelm, Wait-ForKagentAvailable, Write-KagentUsageForUser, Deploy-CopilotCliAgent, Remove-CopilotCliAgent
