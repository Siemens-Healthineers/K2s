# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule

<#
.DESCRIPTION
Gets the location of manifests to deploy dashboard dashboard
#>
function Get-DashboardConfig {
    return "$PSScriptRoot\manifests\dashboard"
}

<#
.DESCRIPTION
Enables the metrics server addon.
#>
function Enable-MetricsServer {
    &"$PSScriptRoot\..\metrics\Enable.ps1" -ShowLogs:$ShowLogs
}

<#
.DESCRIPTION
Writes the usage notes for dashboard for the user.
#>
function Write-DashboardUsageForUser {
    @"
                DASHBOARD ADDON - USAGE NOTES
 To open dashboard, please use one of the options:

 Option 1: Access via ingress
 Please install either ingress nginx or ingress traefik or ingress nginx gateway addon from k2s.
 or you can install them on your own. 
 Enable ingress controller via k2s cli
 eg. k2s addons enable ingress nginx
 Once the ingress controller is running in the cluster, run the command to enable dashboard 
 k2s addons enable dashboard
 the Kubernetes Dashboard will be accessible on the following URL: https://k2s.cluster.local/dashboard/

 Option 2: Port-forwarding
 Use port-forwarding to the kubernetes-dashboard Kong proxy using the command below:
 kubectl port-forward svc/kubernetes-dashboard-kong-proxy -n dashboard 8443:443

 In this case, the Kubernetes Dashboard will be accessible on the following URL: https://localhost:8443
 It is not necessary to use port 8443. Please feel free to use a port number of your choice.

 The dashboard is opened in the browser.

 In case of the security addon enabled you need to provide a Bearer token for authentication.
 For non security addon enabled clusters, a Bearer token is created automatically for the admin user for 24 hours.
 If you want to create such an token, you can run the following command (or disable and enable the dashboard addon again):
    kubectl -n dashboard create token admin-user --duration 24h

 Read more: https://github.com/kubernetes/dashboard/blob/master/README.md
"@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
}

<#
.DESCRIPTION
Waits for the dashboard pods to be available.
#>
function Wait-ForDashboardAvailable {
    return (Wait-ForPodCondition -Condition Ready -Label 'app.kubernetes.io/instance=kubernetes-dashboard' -Namespace 'dashboard' -TimeoutSeconds 200)
}

<#
.DESCRIPTION
Gets the location of manifests to deploy dashboard chart
#>
function Get-DashboardChartDirectory {
    return "$PSScriptRoot\manifests\chart"
}

<#
.DESCRIPTION
Determines if the security service is deployed in the cluster
#>
function Test-SecurityAddonAvailability {
    $existingServices = (Invoke-Kubectl -Params 'get', 'service', '-n', 'security', '-o', 'yaml').Output
    if ("$existingServices" -match '.* keycloak .*') {
        return $true
    }
    return $false
}

<#
.DESCRIPTION
Create a bearer token
#>
function Get-BearerToken {
    # create Bearer token for next 24h
    $token = (Invoke-Kubectl -Params '-n', 'dashboard', 'create', 'token', 'admin-user', '--duration', '24h').Output 
    return $token
}

<#
.DESCRIPTION
Creates kong CA certificate ConfigMap for nginx-gw BackendTLSPolicy validation
#>
function New-KongCACertConfigMap {
    New-BackendCACertConfigMap -Namespace 'dashboard' -PodLabel 'app.kubernetes.io/name=kong' -Port 8443 -ConfigMapName 'kong-ca-cert'
}