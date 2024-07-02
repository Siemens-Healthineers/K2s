
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
    return "$PSScriptRoot\manifests\argocd.yaml"
}

<#
.DESCRIPTION
Gets the location of nginx ingress yaml to expose the addons dashboard
#>
function Get-UpdatesDashboardNginxConfig {
    return "$PSScriptRoot\manifests\updates-nginx-ingress.yaml"
    
}

<#
.DESCRIPTION
Gets the location of traefik ingress yaml to expose the addons dashboard
#>
function Get-UpdatesDashboardTraefikConfig {
    return "$PSScriptRoot\manifests\updates-traefik-ingress.yaml"
    
}


<#
.DESCRIPTION
Determines if Traefik ingress controller is deployed in the cluster
#>
function Test-TraefikIngressControllerAvailability {
    $existingServices = (Invoke-Kubectl -Params 'get', 'service', '-n', 'traefik', '-o', 'yaml').Output
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
    Write-Log 'Deploying nginx ingress manifest for dashboard...' -Console
    $updatesDashboardNginxIngressConfig = Get-UpdatesDashboardNginxConfig

    Invoke-Kubectl -Params 'apply', '-f', $updatesDashboardNginxIngressConfig | Write-Log
}

<#
.DESCRIPTION
Deploys the updates dashboard's ingress manifest for Traefik ingress controller
#>
function Deploy-UpdatesDashboardIngressForTraefik {
    Write-Log 'Deploying traefik ingress manifest for dashboard...' -Console
    $updatesDashboardTraefikIngressConfig = Get-UpdatesDashboardTraefikConfig
    
    Invoke-Kubectl -Params 'apply', '-f', $updatesdashboardTraefikIngressConfig | Write-Log
}

<#
.DESCRIPTION
Enables the ingress-nginx addon for external access.
#>
function Enable-IngressAddon {
    &"$PSScriptRoot\..\ingress-nginx\Enable.ps1" -ShowLogs:$ShowLogs
}

<#
.DESCRIPTION
Enables the traefik addon for external access.
#>
function Enable-TraefikAddon {
    &"$PSScriptRoot\..\traefik\Enable.ps1" -ShowLogs:$ShowLogs
}


<#
.DESCRIPTION
Deploys the ingress manifest for updates dashboard based on the ingress controller detected in the cluster.
#>
function Enable-ExternalAccessIfIngressControllerIsFound {
    if (Test-NginxIngressControllerAvailability) {
        Write-Log 'Deploying nginx ingress for updates dashboard ...' -Console
        Deploy-UpdatesDashboardIngressForNginx
    }
    if (Test-TraefikIngressControllerAvailability) {
        Write-Log 'Deploying traefik ingress for upates dashboard ...' -Console
        Deploy-UpdatesDashboardIngressForTraefik
    }
    Add-HostEntries -Url 'k2s-updates.local'
}