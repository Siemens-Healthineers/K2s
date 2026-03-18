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
Gets the location of static Headlamp Kubernetes manifests
#>
function Get-HeadlampManifestsDirectory {
    return "$PSScriptRoot\manifests\headlamp"
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
Waits for the Headlamp pod to be available.
#>
function Wait-ForHeadlampAvailable {
    return (Wait-ForPodCondition -Condition Ready -Label 'app.kubernetes.io/name=headlamp' -Namespace 'dashboard' -TimeoutSeconds 200)
}

<#
.DESCRIPTION
Writes the usage notes for Headlamp for the user.
#>
function Write-HeadlampUsageForUser {
    @"
                DASHBOARD ADDON (Headlamp) - USAGE NOTES
 To open the Headlamp dashboard, please use one of the options:

 Option 1: Access via ingress
 Please install either ingress nginx, ingress traefik, or ingress nginx gateway addon from k2s.
 or you can install them on your own.
 Enable ingress controller via k2s cli
 eg. k2s addons enable ingress nginx
 Once the ingress controller is running in the cluster, run the command to enable dashboard
 k2s addons enable dashboard
 The Headlamp dashboard will be accessible on the following URL: https://k2s.cluster.local/dashboard/

 Option 2: Port-forwarding
 Use port-forwarding to the headlamp service using the command below:
 kubectl port-forward svc/headlamp -n dashboard 4466:4466

 In this case, the Headlamp dashboard will be accessible on the following URL: http://localhost:4466/dashboard/
 It is not necessary to use port 4466. Please feel free to use a port number of your choice.

 NOTE: Headlamp will show a token login screen - this is expected and normal.
 To log in, generate a ServiceAccount token with the command below and paste it into the login screen:
    kubectl -n dashboard create token headlamp --duration 24h

 Read more: https://headlamp.dev/docs/latest/
"@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
}

Export-ModuleMember -Function Get-HeadlampManifestsDirectory, Enable-MetricsServer, Wait-ForHeadlampAvailable, Write-HeadlampUsageForUser
