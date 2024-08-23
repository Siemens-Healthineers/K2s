
# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule

<#
.SYNOPSIS
Contains common methods for installing and uninstalling updates addon
#>

<#
.DESCRIPTION
Gets the location of manifests to deploy ArgoCD
#>
function Get-UpdatesConfig {
    return "$PSScriptRoot\manifests\argocd\overlay"
}

<#
.DESCRIPTION
Gets the location of nginx ingress yaml to expose the ArgoCD dashboard
#>
function Get-UpdatesDashboardNginxConfig {
    return "$PSScriptRoot\manifests\updates-nginx-ingress.yaml"
    
}

<#
.DESCRIPTION
Gets the location of traefik ingress yaml to expose the ArgoCD dasboard
#>
function Get-UpdatesDashboardTraefikConfig {
    return "$PSScriptRoot\manifests\updates-traefik-ingress.yaml"
    
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
Deploys the updates dashboard's ingress manifest for Nginx ingress controller
#>
function Deploy-UpdatesDashboardIngressForNginx {
    Write-Log 'Deploying nginx ingress manifest for updates dashboard...' -Console
    $updatesDashboardNginxIngressConfig = Get-UpdatesDashboardNginxConfig

    Invoke-Kubectl -Params 'apply', '-f', $updatesDashboardNginxIngressConfig | Write-Log
}

<#
.DESCRIPTION
Deploys the updates dashboard's ingress manifest for Traefik ingress controller
#>
function Deploy-UpdatesDashboardIngressForTraefik {
    Write-Log 'Deploying traefik ingress manifest for updates dashboard...' -Console
    $updatesDashboardTraefikIngressConfig = Get-UpdatesDashboardTraefikConfig
    
    Invoke-Kubectl -Params 'apply', '-f', $updatesdashboardTraefikIngressConfig | Write-Log
}

<#
.DESCRIPTION
Enables a ingress addon based on the input
#>
function Enable-IngressAddon([string]$Ingress) {
    switch ($Ingress) {
        'nginx' {
            &"$PSScriptRoot\..\ingress\nginx\Enable.ps1"
            break
        }
        'traefik' {
            &"$PSScriptRoot\..\ingress\traefik\Enable.ps1"
            break
        }
    }
}


<#
.DESCRIPTION
Deploys the ingress manifest for updates dashboard based on the ingress controller detected in the cluster.
#>
function Enable-ExternalAccessIfIngressControllerIsFound {
    if (Test-NginxIngressControllerAvailability) {
        Deploy-UpdatesDashboardIngressForNginx
    }
    if (Test-TraefikIngressControllerAvailability) {
        Deploy-UpdatesDashboardIngressForTraefik
    }
}

function Write-UsageForUser {
    param (
        [String]$ARGOCD_Password
    )
    @"
                                        USAGE NOTES
 To open ArgoCD dashboard, please use one of the options:
 
 Option 1: Access via ingress
 Please install either ingress nginx addon or ingress traefik addon from k2s.
 or you can install them on your own.
 Enable ingress controller via k2s cli
 eg. k2s addons enable ingress nginx
 Once the ingress controller is running in the cluster, run the command to enable updates again (disable it first if updates addon was already enabled).
 k2s addons enable updates
 The ArgoCD dashboard will be accessible on the following URL: https://k2s.cluster.local/updates/ and https://k2s-updates.cluster.local (with HTTP using http://.. unstead of https://..)

 Option 2: Port-forwading
 Use port-forwarding to the ArgoCD dashboard using the command below:
 kubectl -n updates port-forward svc/argocd-server 8080:443
 
 In this case, the ArgoCD dashboard will be accessible on the following URL: https://localhost:8080
 
 On opening the URL in the browser, the login page appears.
 username: admin
 password: $ARGOCD_Password

 To use the argo cli please login with: argocd login k2s-updates.local

 Please change the password immediately, this can be done via the dashboard or via the cli with: argocd account update-password
"@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
}