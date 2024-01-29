# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Contains common methods for installing and uninstalling Kubernetes Dashboard UI
#>

<#
.DESCRIPTION
Gets the location of manifests to deploy dashboard dashboard
#>
function Get-DashboardConfig {
    return "$PSScriptRoot\manifests\dashboard.yaml"
}

<#
.DESCRIPTION
Gets the location of nginx ingress yaml for dashboard
#>
function Get-DashboardNginxConfig {
    return "$PSScriptRoot\manifests\dashboard-nginx-ingress.yaml"
}

<#
.DESCRIPTION
Gets the location of traefik ingress yaml for dashboard
#>
function Get-DashboardTraefikConfig {
    return "$PSScriptRoot\manifests\dashboard-traefik-ingress.yaml"
}

<#
.DESCRIPTION
Determines if Nginx ingress controller is deployed in the cluster
#>
function Test-NginxIngressControllerAvailability {
    $existingServices = $(&$global:BinPath\kubectl.exe get service -n ingress-nginx -o yaml)
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
    $existingServices = $(&$global:BinPath\kubectl.exe get service -n traefik -o yaml)
    if ("$existingServices" -match '.*traefik.*') {
        return $true
    }
    return $false
}

<#
.DESCRIPTION
Deploys the dashboard's ingress manifest for Nginx ingress controller
#>
function Deploy-DashboardIngressForNginx {
    Write-Log 'Deploying nginx ingress manifest for dashboard...' -Console
    $dashboardNginxIngressConfig = Get-DashboardNginxConfig
    kubectl apply -f $dashboardNginxIngressConfig | Out-Null
}

<#
.DESCRIPTION
Deploys the dashboard's ingress manifest for Traefik ingress controller
#>
function Deploy-DashboardIngressForTraefik {
    Write-Log 'Deploying traefik ingress manifest for dashboard...' -Console
    $dashboardTraefikIngressConfig = Get-DashboardTraefikConfig
    kubectl apply -f $dashboardTraefikIngressConfig | Out-Null
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
Enables the metrics server addon.
#>
function Enable-MetricsServer {
    &"$PSScriptRoot\..\metrics-server\Enable.ps1" -ShowLogs:$ShowLogs
}

<#
.DESCRIPTION
Adds an entry in hosts file for k2s-dashboard.local in both the windows and linux nodes
#>
function Add-DashboardHostEntry {
    Write-Log 'Configuring nodes access' -Console
    $dashboardIPWithIngress = $global:IP_Master
    $dashboardHost = 'k2s-dashboard.local'

    # Enable dashboard access on linux node
    $hostEntry = $($dashboardIPWithIngress + ' ' + $dashboardHost)
    ExecCmdMaster "grep -qxF `'$hostEntry`' /etc/hosts || echo $hostEntry | sudo tee -a /etc/hosts"

    # In case of multi-vm, enable access on windows node
    $K8sSetup = Get-Installedk2sSetupType
    if ($K8sSetup -eq $global:SetupType_MultiVMK8s) {
        $session = Open-RemoteSessionViaSSHKey $global:Admin_WinNode $global:WindowsVMKey

        Invoke-Command -Session $session {
            Set-Location "$env:SystemDrive\k"
            Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

            if (!$(Get-Content 'C:\Windows\System32\drivers\etc\hosts' | % { $_ -match $using:hostEntry }).Contains($true)) {
                Add-Content 'C:\Windows\System32\drivers\etc\hosts' $using:hostEntry
            }
        }
    }

    # finally, add entry in the host to be enable access
    if (!$(Get-Content 'C:\Windows\System32\drivers\etc\hosts' | % { $_ -match $hostEntry }).Contains($true)) {
        Add-Content 'C:\Windows\System32\drivers\etc\hosts' $hostEntry
    }
}

<#
.DESCRIPTION
Deploys the ingress manifest for dashboard based on the ingress controller detected in the cluster.
#>
function Enable-ExternalAccessIfIngressControllerIsFound {
    if (Test-NginxIngressControllerAvailability) {
        Write-Log 'Deploying nginx ingress for dashboard ...' -Console
        Deploy-DashboardIngressForNginx
    }
    if (Test-TraefikIngressControllerAvailability) {
        Write-Log 'Deploying traefik ingress for dashboard ...' -Console
        Deploy-DashboardIngressForTraefik
    }
    Add-DashboardHostEntry
}

<#
.DESCRIPTION
Writes the usage notes for dashboard for the user.
#>
function Write-UsageForUser {
    @"
                                        USAGE NOTES
 To open dashboard, please use one of the options:

 Option 1: Access via ingress
 Please install either ingress-nginx addon or traefik addon from k2s.
 or you can install them on your own. 
 Enable ingress controller via k2s cli
 eg. k2s addons enable ingress-nginx
 Once the ingress controller is running in the cluster, run the command to enable dashboard again.
 k2s addons enable dashboard
 the Kubernetes Dashboard will be accessible on the following URL: https://k2s-dashboard.local

 Option 2: Port-forwarding
 Use port-forwarding to the kubernetes-dashboard using the command below:
 kubectl -n kubernetes-dashboard port-forward svc/kubernetes-dashboard 8443:443

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
    $selector = 'k8s-app=kubernetes-dashboard'
    $namespace = 'kubernetes-dashboard'
    $allDashBoardPodsUp = Wait-ForPodsReady -Selector $selector -Namespace $namespace
    return $allDashBoardPodsUp
}