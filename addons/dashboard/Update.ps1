# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$dashboardModule = "$PSScriptRoot\dashboard.module.psm1"

Import-Module $addonsModule, $dashboardModule

Update-IngressForAddon -Addon ([pscustomobject] @{Name = 'dashboard' })

$SecurityAddonEnabled = Test-SecurityAddonAvailability
if ($SecurityAddonEnabled) {
    Write-Log "Security addon is enabled"
    # remove middleware if exists
    (Invoke-Kubectl -Params 'delete', 'middleware', 'add-bearer-token', '-n', 'dashboard', '--ignore-not-found').Output | Write-Log
} else {
    if (Test-NginxIngressControllerAvailability) {
        # create Bearer token for next 24h
        Write-Log "Creating Bearer token for next 24h"
        $token = Get-BearerToken
        # copy patch template to temp folder
        $tempPath = [System.IO.Path]::GetTempPath()
        Copy-Item -Path "$PSScriptRoot\manifests\ingress-nginx\patch.json" -Destination "$tempPath\patch.json"
        # replace content of file
        Write-Log "Replacing content of patch file"
        (Get-Content -Path "$tempPath\patch.json").replace('BEARER-TOKEN', $token) | Out-File -FilePath "$tempPath\patch.json"
        # apply patch
        (Invoke-Kubectl -Params 'patch', 'ingress', 'dashboard-nginx-cluster-local', '-n', 'dashboard', '--patch-file', "$tempPath\patch.json", $annotations).Output | Write-Log
        # delete patch file
        Remove-Item -Path "$tempPath\patch.json"
    }
    elseif (Test-TraefikIngressControllerAvailability) {
        # create Bearer token for next 24h
        Write-Log "Creating Bearer token for next 24h"
        $token = Get-BearerToken
        # create middleware
        $middleware = "apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
    name: add-bearer-token
    namespace: dashboard
spec:
    headers: 
        customRequestHeaders: 
            Authorization: Bearer $token"
        $tempPath = [System.IO.Path]::GetTempPath()
        $middleware | Out-File -FilePath "$tempPath\middleware.yaml"
        (Invoke-Kubectl -Params 'apply', '-f', "$tempPath\middleware.yaml", '-n', 'dashboard').Output | Write-Log
        # delete middleware file
        Remove-Item -Path "$tempPath\middleware.yaml"
    }
    else {
        Write-Log "Nginx or Traefik ingress controller is not available"
    }
}

$EnancedSecurityEnabled = Test-LinkerdServiceAvailability
if ($EnancedSecurityEnabled) {
    Write-Log "Updating dashboard addon to be part of service mesh"  
    $annotations1 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/skip-inbound-ports\":\"443\"}}}}}'
    (Invoke-Kubectl -Params 'patch', 'deployment', 'kubernetes-dashboard-kong', '-n', 'dashboard', '-p', $annotations1).Output | Write-Log
    $annotations2 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\"}}}}}'
    (Invoke-Kubectl -Params 'patch', 'deployment', 'kubernetes-dashboard-api', '-n', 'dashboard', '-p', $annotations2).Output | Write-Log
    $annotations3 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\"}}}}}'
    (Invoke-Kubectl -Params 'patch', 'deployment', 'kubernetes-dashboard-auth', '-n', 'dashboard', '-p', $annotations3).Output | Write-Log
    $annotations4 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\"}}}}}'
    (Invoke-Kubectl -Params 'patch', 'deployment', 'kubernetes-dashboard-metrics-scraper', '-n', 'dashboard', '-p', $annotations4).Output | Write-Log
    $annotations5 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\"}}}}}'
    (Invoke-Kubectl -Params 'patch', 'deployment', 'kubernetes-dashboard-web', '-n', 'dashboard', '-p', $annotations5).Output | Write-Log
} else {
    Write-Log "Updating dashboard addon to not be part of service mesh"
    $annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config.linkerd.io/skip-inbound-ports\":null,\"linkerd.io/inject\":null}}}}}'
    (Invoke-Kubectl -Params 'patch', 'deployment', 'kubernetes-dashboard-kong', '-n', 'dashboard', '-p', $annotations).Output | Write-Log
    (Invoke-Kubectl -Params 'patch', 'deployment', 'kubernetes-dashboard-api', '-n', 'dashboard', '-p', $annotations).Output | Write-Log
    (Invoke-Kubectl -Params 'patch', 'deployment', 'kubernetes-dashboard-auth', '-n', 'dashboard', '-p', $annotations).Output | Write-Log
    (Invoke-Kubectl -Params 'patch', 'deployment', 'kubernetes-dashboard-metrics-scraper', '-n', 'dashboard', '-p', $annotations).Output | Write-Log
    (Invoke-Kubectl -Params 'patch', 'deployment', 'kubernetes-dashboard-web', '-n', 'dashboard', '-p', $annotations).Output | Write-Log
}
(Invoke-Kubectl -Params 'rollout', 'status', 'deployment', '-n', 'dashboard', '--timeout', '60s').Output | Write-Log

Write-Log 'Updating dashboard addon finished.' -Console