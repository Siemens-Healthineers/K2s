# SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule

<#
.DESCRIPTION
Gets the location of manifests to deploy viewer viewer
#>
function Get-ViewerConfig {
    return "$PSScriptRoot\manifests\viewer"
}

<#
.DESCRIPTION
Writes the usage notes for viewer for the user.
#>
function Write-ViewerUsageForUser {
    @"
                VIEWER ADDON - USAGE NOTES
 To open the viewer, please use one of the options:

 Option 1: Access via ingress
 Please install either ingress nginx or ingress traefik addon from k2s
 or you can install them on your own. 
 Enable ingress controller via k2s cli
 eg. k2s addons enable ingress nginx
 Once the ingress controller is running in the cluster, run the command to enable viewer 
 k2s addons enable viewer
 the viewer will be accessible on the following URL: http://k2s.cluster.local/viewer

 Option 2: Port-forwarding
 Use port-forwarding to the viewer using the command below:
 kubectl -n viewer port-forward svc/viewerwebapp 8443:80

 In this case, the viewer will be accessible on the following URL: http://localhost:8443/viewer/
 It is not necessary to use port 8443. Please feel free to use a port number of your choice.


 On opening the URL in the browser, the login page appears.
 Please select `"Skip`".

 The viewer is opened in the browser.
 
"@ -split "`n" | ForEach-Object { Write-Log $_ -Console }
}

<#
.DESCRIPTION
Waits for the viewer pods to be available.
#>
function Wait-ForViewerAvailable {
    return (Wait-ForPodCondition -Condition Ready -Label 'app=viewerwebapp' -Namespace 'viewer' -TimeoutSeconds 120)
}