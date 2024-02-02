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
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
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
    @'
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
'@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
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
    $existingServices = $(&$global:KubectlExe get service -n traefik -o yaml)
    if ("$existingServices" -match '.*traefik.*') {
        return $true
    }
    return $false
}

&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1

$logModule = "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
$statusModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/status/status.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$cliMessagesModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/cli-messages/cli-messages.module.psm1"

Import-Module $logModule, $addonsModule, $statusModule, $cliMessagesModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Checking cluster status' -Console

$systemError = Test-SystemAvailability
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError -Error
    exit 1
}

if ((Test-IsAddonEnabled -Name 'monitoring') -eq $true) {
    Write-Log "Addon 'monitoring' is already enabled, nothing to do." -Console

    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null }
    }
    
    exit 0
}

if ($Ingress -ne 'none') {
    Enable-IngressAddon -Ingress:$Ingress
}

Write-Log 'Installing Kube Prometheus Stack' -Console
&$global:KubectlExe apply -f "$global:KubernetesPath\addons\monitoring\manifests\namespace.yaml"
&$global:KubectlExe create -f "$global:KubernetesPath\addons\monitoring\manifests\crds" 
&$global:KubectlExe create -k "$global:KubernetesPath\addons\monitoring\manifests"

Write-Log 'Waiting for pods...'
&$global:KubectlExe rollout status deployments -n monitoring --timeout=180s
if (!$?) {
    $errMsg = 'Kube Prometheus Stack could not be deployed successfully!'
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $errMsg }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}
&$global:KubectlExe rollout status statefulsets -n monitoring --timeout=180s
if (!$?) {
    $errMsg = 'Kube Prometheus Stack could not be deployed successfully!'
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $errMsg }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}
&$global:KubectlExe rollout status daemonsets -n monitoring --timeout=180s
if (!$?) {
    $errMsg = 'Kube Prometheus Stack could not be deployed successfully!'
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $errMsg }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

# traefik uses crd, so we have define ingressRoute after traefik has been enabled
if (Test-TraefikIngressControllerAvailability) {
    &$global:KubectlExe apply -f "$global:KubernetesPath\addons\monitoring\manifests\plutono\traefik.yaml"
}
Add-DashboardHostEntry

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'monitoring' })
Write-Log 'Kube Prometheus Stack installed successfully'

Write-UsageForUser

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}