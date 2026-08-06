# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"
$rolloutModule = "$PSScriptRoot\rollout.module.psm1"

Import-Module $addonsModule, $rolloutModule

function Invoke-RolloutDiagKubectl {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Params,
        [Parameter(Mandatory = $true)]
        [string] $Description
    )

    Write-Log "[RolloutDiag] kubectl $Description" -Console
    $result = Invoke-Kubectl -Params $Params

    if (-not [string]::IsNullOrWhiteSpace($result.Output)) {
        $result.Output | Write-Log
    }

    if (-not $result.Success) {
        Write-Log "[RolloutDiag] Command failed: kubectl $Description" -Console
    }

    return $result
}

function Capture-RolloutTimeoutDiagnostics {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Reason
    )

    Write-Log "[RolloutDiag] Capturing diagnostics because: $Reason" -Console

    $snapshotCommands = @(
        @{ Description = 'get pods -n rollout -o wide'; Params = @('get', 'pods', '-n', 'rollout', '-o', 'wide') },
        @{ Description = 'get deployments -n rollout -o wide'; Params = @('get', 'deployments', '-n', 'rollout', '-o', 'wide') },
        @{ Description = 'get statefulsets -n rollout -o wide'; Params = @('get', 'statefulsets', '-n', 'rollout', '-o', 'wide') },
        @{ Description = 'get replicasets -n rollout -o wide'; Params = @('get', 'replicasets', '-n', 'rollout', '-o', 'wide') },
        @{ Description = 'get events -n rollout --sort-by=.lastTimestamp'; Params = @('get', 'events', '-n', 'rollout', '--sort-by=.lastTimestamp') },
        @{ Description = 'describe deployment argocd-applicationset-controller -n rollout'; Params = @('describe', 'deployment', 'argocd-applicationset-controller', '-n', 'rollout') },
        @{ Description = 'describe deployment argocd-dex-server -n rollout'; Params = @('describe', 'deployment', 'argocd-dex-server', '-n', 'rollout') },
        @{ Description = 'describe deployment argocd-notifications-controller -n rollout'; Params = @('describe', 'deployment', 'argocd-notifications-controller', '-n', 'rollout') },
        @{ Description = 'describe deployment argocd-redis -n rollout'; Params = @('describe', 'deployment', 'argocd-redis', '-n', 'rollout') },
        @{ Description = 'describe deployment argocd-repo-server -n rollout'; Params = @('describe', 'deployment', 'argocd-repo-server', '-n', 'rollout') },
        @{ Description = 'describe deployment argocd-server -n rollout'; Params = @('describe', 'deployment', 'argocd-server', '-n', 'rollout') },
        @{ Description = 'describe statefulset argocd-application-controller -n rollout'; Params = @('describe', 'statefulset', 'argocd-application-controller', '-n', 'rollout') }
    )

    foreach ($entry in $snapshotCommands) {
        Invoke-RolloutDiagKubectl -Params $entry.Params -Description $entry.Description | Out-Null
    }

    $podNamesResult = Invoke-RolloutDiagKubectl -Params @('get', 'pods', '-n', 'rollout', '-o', 'name') -Description 'get pods -n rollout -o name'
    if (-not $podNamesResult.Success) {
        Write-Log '[RolloutDiag] Unable to enumerate rollout namespace pods for per-pod diagnostics.' -Console
        return
    }

    $podNames = @($podNamesResult.Output -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    foreach ($podName in $podNames) {
        Invoke-RolloutDiagKubectl -Params @('describe', $podName, '-n', 'rollout') -Description "describe $podName -n rollout" | Out-Null
        Invoke-RolloutDiagKubectl -Params @('logs', $podName, '-n', 'rollout', '--all-containers=true', '--tail=200') -Description "logs $podName -n rollout --all-containers=true --tail=200" | Out-Null
        Invoke-RolloutDiagKubectl -Params @('logs', $podName, '-n', 'rollout', '--all-containers=true', '--previous', '--tail=200') -Description "logs $podName -n rollout --all-containers=true --previous --tail=200" | Out-Null
    }
}

Update-IngressForAddon -Addon ([pscustomobject] @{Name = 'rollout'; Implementation = 'argocd' })

$EnancedSecurityEnabled = Test-LinkerdServiceAvailability
if ($EnancedSecurityEnabled) {
    Write-Log "Updating rollout addon to be part of service mesh"  
    (Invoke-Kubectl -Params 'annotate', 'namespace', 'rollout', 'linkerd.io/inject=enabled', '--overwrite').Output | Write-Log
    (Invoke-Kubectl -Params 'annotate', 'namespace', 'rollout', 'config.linkerd.io/skip-outbound-ports=8181', '--overwrite').Output | Write-Log

    if (Test-NginxGatewayAvailability) {
        Write-Log "Configuring Linkerd to skip inbound port 8080 for nginx-gw BackendTLSPolicy" -Console
        $annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/skip-inbound-ports\":\"8080\"}}}}}'
        (Invoke-Kubectl -Params 'patch', 'deployment', 'argocd-server', '-n', 'rollout', '-p', $annotations).Output | Write-Log
    }
} else {
    Write-Log "Updating rollout addon to not be part of service mesh"
    (Invoke-Kubectl -Params 'annotate', 'namespace', 'rollout', 'linkerd.io/inject-').Output | Write-Log
    (Invoke-Kubectl -Params 'annotate', 'namespace', 'rollout', 'config.linkerd.io/skip-outbound-ports-').Output | Write-Log
}
(Invoke-Kubectl -Params 'rollout', 'restart', 'deployment', '-n', 'rollout').Output | Write-Log
(Invoke-Kubectl -Params 'rollout', 'restart', 'statefulset', '-n', 'rollout').Output | Write-Log

$deploymentRollout = Invoke-Kubectl -Params 'rollout', 'status', 'deployment', '-n', 'rollout', '--timeout', '180s'
$deploymentRollout.Output | Write-Log
if (-not $deploymentRollout.Success) {
    Write-Log '[Rollout] ArgoCD deployment rollout status check failed during update.' -Error
    Capture-RolloutTimeoutDiagnostics -Reason 'ArgoCD deployment rollout status failed after restart in Update.ps1'
    exit 1
}

$statefulsetRollout = Invoke-Kubectl -Params 'rollout', 'status', 'statefulset', '-n', 'rollout', '--timeout', '180s'
$statefulsetRollout.Output | Write-Log
if (-not $statefulsetRollout.Success) {
    Write-Log '[Rollout] ArgoCD statefulset rollout status check failed during update.' -Error
    Capture-RolloutTimeoutDiagnostics -Reason 'ArgoCD statefulset rollout status failed after restart in Update.ps1'
    exit 1
}

if (Test-NginxGatewayAvailability) {
    Write-Log 'Creating ArgoCD CA certificate ConfigMap for nginx-gw BackendTLSPolicy' -Console
    Start-Sleep -Seconds 20 
    New-BackendCACertConfigMap -Namespace 'rollout' -PodLabel 'app.kubernetes.io/name=argocd-server' -Port 8080 -ConfigMapName 'argocd-ca-cert'
}