# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$logModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/log/log.module.psm1"
$k8sApiModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k8s-api/k8s-api.module.psm1"

Import-Module $logModule, $k8sApiModule

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
Writes the usage notes for dashboard for the user.
#>
function Write-UsageForUser {
    @'
                                        USAGE NOTES
 To open plutono dashboard, please use one of the options:
 
 Option 1: Access via ingress
 Please install either ingress nginx addon or ingress traefik addon from k2s.
 or you can install them on your own.
 Enable ingress controller via k2s cli
 eg. k2s addons enable ingress nginx
 Once the ingress controller is running in the cluster, run the command to enable monitoring
 k2s addons enable monitoring
 The plutono dashboard will be accessible on the following URL: https://k2s.cluster.local/monitoring/ 
 Option 2: Port-forwading
 Use port-forwarding to the plutono dashboard using the command below:
 kubectl -n monitoring port-forward svc/kube-prometheus-stack-plutono 3000:443
 
 In this case, the plutono dashboard will be accessible on the following URL: https://localhost:3000/monitoring/
 
 On opening the URL in the browser, the login page appears.
 username: admin
 password: admin
'@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
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
