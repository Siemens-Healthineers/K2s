# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Deploys the K2s ClusterIP mutating webhook to the cluster.

.DESCRIPTION
This script deploys the clusterip-webhook components:
  1. Namespace
  2. RBAC (ServiceAccounts, ClusterRoles, Roles, Bindings)
  3. MutatingWebhookConfiguration
  4. TLS cert generation Job (creates self-signed cert)
  5. Webhook Deployment + Service
  6. TLS cert patch Job (injects caBundle into webhook config)

The webhook automatically assigns ClusterIPs from the correct subnet
(Linux 172.21.0.x or Windows 172.21.1.x) by detecting the target OS from
the workloads (Deployments, StatefulSets, DaemonSets) that the Service
selects.

.PARAMETER IpAddress
The IP address of the Linux master node.

.PARAMETER UserName
The SSH user name for the master node.

.PARAMETER UserPwd
The SSH password for the master node.
#>

param(
    [parameter(Mandatory = $true)]
    [string]$IpAddress,
    [parameter(Mandatory = $true)]
    [string]$UserName,
    [parameter(Mandatory = $true)]
    [string]$UserPwd
)

$infraModule = "$PSScriptRoot\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
Import-Module $infraModule, $nodeModule

$manifestDir = "$PSScriptRoot\..\manifests\clusterip-webhook"

function Deploy-ClusterIPWebhook {
    param(
        [string]$IpAddress,
        [string]$UserName,
        [string]$UserPwd
    )

    $executeRemoteCommand = {
        param($Command, [switch]$IgnoreErrors, [int]$Retries = 0)
        Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $Command `
            -RemoteUser "$UserName" -RemoteUserPwd "$UserPwd" `
            -Retries $Retries -IgnoreErrors:$IgnoreErrors
    }

    Write-Log '[ClusterIP-Webhook] Deploying clusterip-webhook components' -Console

    # Step 1: Copy manifests to the master node
    Write-Log '[ClusterIP-Webhook] Copying manifests to master node'
    $remoteDir = '/tmp/clusterip-webhook'
    &$executeRemoteCommand "mkdir -p $remoteDir"

    $manifestFiles = @(
        'namespace.yaml',
        'rbac.yaml',
        'webhook-config.yaml',
        'certgen-create-job.yaml',
        'certgen-patch-job.yaml',
        'deployment.yaml'
    )

    foreach ($file in $manifestFiles) {
        $localPath = Join-Path $manifestDir $file
        Copy-ToControlPlaneViaUserAndPwd -Source $localPath `
            -Target "$remoteDir/$file" `
            -RemoteUser $UserName -RemoteUserPwd $UserPwd
    }

    # Step 2: Apply in order — namespace and RBAC first
    Write-Log '[ClusterIP-Webhook] Creating namespace and RBAC'
    &$executeRemoteCommand "kubectl apply -f $remoteDir/namespace.yaml" -Retries 3
    &$executeRemoteCommand "kubectl apply -f $remoteDir/rbac.yaml" -Retries 3

    # Step 3: Apply webhook config (caBundle empty, will be patched by Job)
    Write-Log '[ClusterIP-Webhook] Applying MutatingWebhookConfiguration'
    &$executeRemoteCommand "kubectl apply -f $remoteDir/webhook-config.yaml" -Retries 3

    # Step 4: Run TLS cert-create Job and wait for completion
    Write-Log '[ClusterIP-Webhook] Running TLS certificate create job'
    &$executeRemoteCommand "kubectl apply -f $remoteDir/certgen-create-job.yaml" -Retries 3

    Write-Log '[ClusterIP-Webhook] Waiting for cert-create job to complete'
    &$executeRemoteCommand "kubectl wait --for=condition=complete job/clusterip-webhook-certgen-create -n k2s-webhook --timeout=120s" -Retries 3

    # Step 5: Run TLS cert-patch Job and wait for completion
    Write-Log '[ClusterIP-Webhook] Running TLS certificate patch job'
    &$executeRemoteCommand "kubectl apply -f $remoteDir/certgen-patch-job.yaml" -Retries 3

    Write-Log '[ClusterIP-Webhook] Waiting for cert-patch job to complete'
    &$executeRemoteCommand "kubectl wait --for=condition=complete job/clusterip-webhook-certgen-patch -n k2s-webhook --timeout=120s" -Retries 3

    # Step 6: Apply Deployment + Service (after TLS secret exists)
    Write-Log '[ClusterIP-Webhook] Applying Deployment and Service'
    &$executeRemoteCommand "kubectl apply -f $remoteDir/deployment.yaml" -Retries 3

    # Step 7: Wait for webhook deployment to be ready
    Write-Log '[ClusterIP-Webhook] Waiting for webhook deployment to be ready'
    &$executeRemoteCommand "kubectl rollout status deployment/clusterip-webhook -n k2s-webhook --timeout=120s" -Retries 3

    # Step 9: Cleanup temp files
    &$executeRemoteCommand "rm -rf $remoteDir" -IgnoreErrors

    Write-Log '[ClusterIP-Webhook] ClusterIP webhook deployed successfully' -Console
}

function Remove-ClusterIPWebhook {
    param(
        [string]$IpAddress,
        [string]$UserName,
        [string]$UserPwd
    )

    $executeRemoteCommand = {
        param($Command, [switch]$IgnoreErrors, [int]$Retries = 0)
        Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $Command `
            -RemoteUser "$UserName" -RemoteUserPwd "$UserPwd" `
            -Retries $Retries -IgnoreErrors:$IgnoreErrors
    }

    Write-Log '[ClusterIP-Webhook] Removing clusterip-webhook components' -Console

    &$executeRemoteCommand 'kubectl delete mutatingwebhookconfiguration k2s-webhook --ignore-not-found' -IgnoreErrors
    &$executeRemoteCommand 'kubectl delete namespace k2s-webhook --ignore-not-found' -IgnoreErrors
    &$executeRemoteCommand 'kubectl delete clusterrole k2s:clusterip-webhook k2s:clusterip-webhook-certgen --ignore-not-found' -IgnoreErrors
    &$executeRemoteCommand 'kubectl delete clusterrolebinding k2s:clusterip-webhook k2s:clusterip-webhook-certgen --ignore-not-found' -IgnoreErrors

    Write-Log '[ClusterIP-Webhook] ClusterIP webhook removed' -Console
}

# Main execution
Deploy-ClusterIPWebhook -IpAddress $IpAddress -UserName $UserName -UserPwd $UserPwd
