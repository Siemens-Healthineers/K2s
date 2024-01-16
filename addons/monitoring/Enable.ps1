# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Enables Prometheus/Grafana monitoring features for the k2s cluster.

.DESCRIPTION
The "monitoring" addons enables Prometheus/Grafana monitoring features for the k2s cluster.

#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [ValidateSet('ingress-nginx', 'traefik', 'none')]
    [string] $Ingress = 'none',
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
    [pscustomobject] $Config
)

# load global settings
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1

. $PSScriptRoot\Common.ps1

Import-Module "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
Initialize-Logging -ShowLogs:$ShowLogs

$addonsModule = "$PSScriptRoot\..\Addons.module.psm1"
Import-Module $addonsModule

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
Writes the usage notes for dashboard for the user.
#>
function Write-UsageForUser {
@"
                                        USAGE NOTES
 To open plutono dashboard, please use one of the options:
 
 Option 1: Access via ingress
 Please install either ingress-nginx addon or traefik addon from k2s.
 or you can install them on your own.
 Enable ingress controller via k2s cli
 eg. k2s addons enable ingress-nginx
 Once the ingress controller is running in the cluster, run the command to enable monitoring again.
 k2s addons enable monitoring
 The plutono dashboard will be accessible on the following URL: https://k2s-monitoring.local

 Option 2: Port-forwading
 Use port-forwarding to the kubernetes-dashboard using the command below:
 kubectl -n monitoring port-forward svc/kube-prometheus-stack-plutono 3000:443
 
 In this case, the plutono dashboard will be accessible on the following URL: https://localhost:3000
 
 On opening the URL in the browser, the login page appears.
 username: admin
 password: admin
"@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
}

<#
.DESCRIPTION
Adds an entry in hosts file for k2s-monitoring.local in both the windows and linux nodes
#>
function Add-DashboardHostEntry {
    Write-Log 'Configuring nodes access' -Console
    $dashboardIPWithIngress = $global:IP_Master
    $grafanaHost = 'k2s-monitoring.local'

    # Enable dashboard access on linux node
    $hostEntry = $($dashboardIPWithIngress + ' ' + $grafanaHost)
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
Determines if Traefik ingress controller is deployed in the cluster
#>
function Test-TraefikIngressControllerAvailability {
    $existingServices = $(&$global:BinPath\kubectl.exe get service -n traefik -o yaml)
    if ("$existingServices" -match '.*traefik.*') {
        return $true
    }
    return $false
}


Write-Log 'Checking cluster status' -Console
Test-ClusterAvailability

if ((Test-IsAddonEnabled -Name 'monitoring') -eq $true) {
    Write-Log "Addon 'monitoring' is already enabled, nothing to do." -Console
    exit 0
}

if ($Ingress -ne 'none') {
    Enable-IngressAddon -Ingress:$Ingress
}

Write-Log 'Installing Kube Prometheus Stack' -Console
kubectl apply -f "$global:KubernetesPath\addons\monitoring\manifests\namespace.yaml"
kubectl create -f "$global:KubernetesPath\addons\monitoring\manifests\crds" 
kubectl create -k "$global:KubernetesPath\addons\monitoring\manifests"

Write-Log 'Waiting for pods...'
kubectl rollout status deployments -n monitoring --timeout=180s
if (!$?) {
    Log-ErrorWithThrow 'Kube Prometheus Stack could not be deployed successfully!'
}
kubectl rollout status statefulsets -n monitoring --timeout=180s
if (!$?) {
    Log-ErrorWithThrow 'Kube Prometheus Stack could not be deployed successfully!'
}
kubectl rollout status daemonsets -n monitoring --timeout=180s
if (!$?) {
    Log-ErrorWithThrow 'Kube Prometheus Stack could not be deployed successfully!'
}

# traefik uses crd, so we have define ingressRoute after traefik has been enabled
if (Test-TraefikIngressControllerAvailability) {
    kubectl apply -f "$global:KubernetesPath\addons\monitoring\manifests\plutono\traefik.yaml"
}
Add-DashboardHostEntry

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'monitoring' })
Write-Log 'Kube Prometheus Stack installed successfully'

Write-UsageForUser
