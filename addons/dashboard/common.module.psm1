# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
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
Gets the location of nginx ingress yaml for dashboard
#>
function Get-DashboardNginxConfig {
    return "$PSScriptRoot\manifests\ingress-nginx"
}

<#
.DESCRIPTION
Gets the location of secure nginx ingress yaml for dashboard
#>
function Get-DashboardSecureNginxConfig {
    return "$PSScriptRoot\manifests\secure-nginx"
}

<#
.DESCRIPTION
Gets the location of traefik ingress yaml for dashboard
#>
function Get-DashboardTraefikConfig {
    return "$PSScriptRoot\manifests\ingress-traefik"
}

<#
.DESCRIPTION
Determines if Nginx ingress controller is deployed in the cluster
#>
function Test-NginxIngressControllerAvailability {
    $existingServices = (Invoke-Kubectl -Params 'get', 'service', '-n', 'ingress-nginx', '-o', 'yaml').Output 
    if ("$existingServices" -match '.*ingress-nginx-controller.*') {
        return $true
    }
    return $false
}

<#
.DESCRIPTION
Determines if Traefik ingress controller is deployed in the cluster
#>
function Test-TraefikIngressControllerAvailability {
    $existingServices = (Invoke-Kubectl -Params 'get', 'service', '-n', 'ingress-traefik', '-o', 'yaml').Output
    if ("$existingServices" -match '.*traefik.*') {
        return $true
    }
    return $false
}

<#
.DESCRIPTION
Determines if KeyCloak is deployed in the cluster
#>
function Test-KeyCloakServiceAvailability {
    $existingServices = (Invoke-Kubectl -Params 'get', 'service', '-n', 'security', '-o', 'yaml').Output
    if ("$existingServices" -match '.*keycloak.*') {
        return $true
    }
    return $false
}

<#
.DESCRIPTION
Deploys the dashboard's ingress manifest for Nginx ingress controller
#>
function Update-DashboardIngressForNginx {
    if (Test-KeyCloakServiceAvailability) {
        Write-Log 'Applying secure nginx ingress manifest for dashboard...' -Console
        $kustomizationDir = Get-DashboardSecureNginxConfig
    }
    else {
        $kustomizationDir = Get-DashboardNginxConfig
        Write-Log 'Applying nginx ingress manifest for dashboard...' -Console
    }
    Invoke-Kubectl -Params 'apply', '-k', $kustomizationDir | Out-Null
}

<#
.DESCRIPTION
Delete the dashboard's ingress manifest for Nginx ingress controller
#>
function Remove-DashboardIngressForNginx {
    # SecureNginxConfig is a superset of NginsConfig, so we delete that:
    $kustomizationDir = Get-DashboardSecureNginxConfig
    Invoke-Kubectl -Params 'delete', '-k', $kustomizationDir | Out-Null
}

<#
.DESCRIPTION
Deploys the dashboard's ingress manifest for Traefik ingress controller
#>
function Update-DashboardIngressForTraefik {
    Write-Log 'Applying traefik ingress manifest for dashboard...' -Console
    $dashboardTraefikIngressConfig = Get-DashboardTraefikConfig
    
    Invoke-Kubectl -Params 'apply', '-k', $dashboardTraefikIngressConfig | Out-Null
}

<#
.DESCRIPTION
Delete the dashboard's ingress manifest for Traefik ingress controller
#>
function Remove-DashboardIngressForTraefik {
    Write-Log 'Deleting traefik ingress manifest for dashboard...' -Console
    $dashboardTraefikIngressConfig = Get-DashboardTraefikConfig
    
    Invoke-Kubectl -Params 'delete', '-k', $dashboardTraefikIngressConfig | Out-Null
}

<#
.DESCRIPTION
Enables the ingress nginx addon for external access.
#>
function Enable-IngressAddon {
    &"$PSScriptRoot\..\ingress\nginx\Enable.ps1" -ShowLogs:$ShowLogs
}

<#
.DESCRIPTION
Enables the traefik addon for external access.
#>
function Enable-TraefikAddon {
    &"$PSScriptRoot\..\ingress\traefik\Enable.ps1" -ShowLogs:$ShowLogs
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
Updates the ingress manifest for dashboard based on the ingress controller detected in the cluster.
#>
function Update-DashboardIngressConfiguration {
    if (Test-NginxIngressControllerAvailability) {
        Remove-DashboardIngressForTraefik
        Update-DashboardIngressForNginx
    }
    elseif (Test-TraefikIngressControllerAvailability) {
        Remove-DashboardIngressForNginx
        Update-DashboardIngressForTraefik
    }
    else {
        Remove-DashboardIngressForNginx
        Remove-DashboardIngressForTraefik
    }
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
 Please install either ingress nginx or ingress traefik addon from k2s.
 or you can install them on your own. 
 Enable ingress controller via k2s cli
 eg. k2s addons enable ingress nginx
 Once the ingress controller is running in the cluster, run the command to enable dashboard again 
 (disable it first if dashboard addon was already enabled).
 k2s addons enable dashboard
 the Kubernetes Dashboard will be accessible on
 https://k2s.cluster.local/dashboard/

 Option 2: Port-forwarding
 Use port-forwarding to the kubernetes-dashboard using the command below:
 kubectl -n dashboard port-forward svc/kubernetes-dashboard 8443:443

 In this case, the Kubernetes Dashboard will be accessible on the following URL: https://localhost:8443
 It is not necessary to use port 8443. Please feel free to use a port number of your choice.


 On opening the URL in the browser, the login page appears.
 Please select `"Skip`".

 The dashboard is opened in the browser.

 Read more: https://github.com/kubernetes/dashboard/blob/master/README.md
"@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
}

<#
.DESCRIPTION
Waits for the dashboard pods to be available.
#>
function Wait-ForDashboardAvailable {
    return (Wait-ForPodCondition -Condition Ready -Label 'k8s-app=kubernetes-dashboard' -Namespace 'dashboard' -TimeoutSeconds 120)
}