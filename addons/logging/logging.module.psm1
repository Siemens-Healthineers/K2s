# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$logModule = "$PSScriptRoot/../../lib\modules\k2s\k2s.infra.module\log\log.module.psm1"
$k8sApiModule = "$PSScriptRoot/../../lib\modules\k2s\k2s.cluster.module\k8s-api\k8s-api.module.psm1"

Import-Module $logModule, $k8sApiModule

function Enable-IngressAddon([string]$Ingress) {
    switch ($Ingress) {
        'ingress-nginx' {
            &"$PSScriptRoot\..\ingress-nginx\Enable.ps1"
            break
        }
        'traefik' {
            &"$PSScriptRoot\..\traefik\Enable.ps1"
            break
        }
    }
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
Writes the usage notes for dashboard for the user.
#>
function Write-UsageForUser {
    @'
                                        USAGE NOTES
 To open opensearch dashboard, please use one of the options:
 
 Option 1: Access via ingress
 Please install either ingress-nginx addon or traefik addon from k2s.
 or you can install them on your own.
 Enable ingress controller via k2s cli
 eg. k2s addons enable ingress-nginx
 Once the ingress controller is running in the cluster, run the command to enable logging again.
 k2s addons enable logging
 The opensearch dashboard will be accessible on the following URL: http://k2s-logging.local

 Option 2: Port-forwading
 Use port-forwarding to the opensearch dashboard using the command below:
 kubectl -n logging port-forward svc/opensearch-dashboards 5601:5601
 
 In this case, the opensearch dashboard will be accessible on the following URL: http://localhost:5601
'@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
}