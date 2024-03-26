# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Enables k2s-logging in the cluster to the logging namespace

.DESCRIPTION
The logging addon collects all logs from containers/pods running inside the k2s cluster.
Logs can be analyzed via opensearch dashboards.

.EXAMPLE
# For k2sSetup
powershell <installation folder>\addons\logging\Enable.ps1
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'External access option')]
    [ValidateSet('ingress-nginx', 'traefik', 'none')]
    [string] $Ingress = 'none',
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
Adds an entry in hosts file for k2s-logging.local in both the windows and linux nodes
#>
function Add-DashboardHostEntry {
    Write-Log 'Configuring nodes access' -Console
    $dashboardIPWithIngress = $global:IP_Master
    $loggingHost = 'k2s-logging.local'

    # Enable dashboard access on linux node
    $hostEntry = $($dashboardIPWithIngress + ' ' + $loggingHost)
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
 The opensearch dashboard will be accessible on the following URL: https://k2s-logging.local

 Option 2: Port-forwading
 Use port-forwarding to the opensearch dashboard using the command below:
 kubectl -n logging port-forward svc/opensearch-dashboards 5601:5601
 
 In this case, the opensearch dashboard will be accessible on the following URL: https://localhost:5601
'@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
}

&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1

$logModule = "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
$statusModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/status/status.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"

Import-Module $logModule, $addonsModule, $statusModule, $infraModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Checking cluster status' -Console

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

if ((Test-IsAddonEnabled -Name 'logging') -eq $true) {
    $errMsg = "Addon 'logging' is already enabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

if ($Ingress -ne 'none') {
    Enable-IngressAddon -Ingress:$Ingress
}

ExecCmdMaster 'sudo mkdir -m 777 -p /logging'

Write-Log 'Installing fluent-bit and opensearch stack' -Console
&$global:KubectlExe apply -f "$global:KubernetesPath\addons\logging\manifests\namespace.yaml"
&$global:KubectlExe create -k "$global:KubernetesPath\addons\logging\manifests\opensearch"
&$global:KubectlExe create -k "$global:KubernetesPath\addons\logging\manifests\opensearch-dashboards"

Write-Log 'Waiting for pods...'
&$global:KubectlExe rollout status deployments -n logging --timeout=180s
if (!$?) {
    $errMsg = 'Opensearch dashboards could not be deployed successfully!'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}
&$global:KubectlExe rollout status statefulsets -n logging --timeout=180s
if (!$?) {
    $errMsg = 'Opensearch could not be deployed successfully!'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

&$global:KubectlExe create -k "$global:KubernetesPath\addons\logging\manifests\fluentbit"

&$global:KubectlExe rollout status daemonsets -n logging --timeout=180s
if (!$?) {
    $errMsg = 'Fluent-bit could not be deployed successfully!'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

# traefik uses crd, so we have define ingressRoute after traefik has been enabled
if (Test-TraefikIngressControllerAvailability) {
    &$global:KubectlExe apply -f "$global:KubernetesPath\addons\logging\manifests\opensearch-dashboards\traefik.yaml"
}
Add-DashboardHostEntry

# Import saved objects 
$dashboardIP = kubectl get pods -l="app.kubernetes.io/name=opensearch-dashboards" -n logging -o=jsonpath="{.items[0].status.podIP}"
$importingSavedObjects = curl.exe -X POST --retry 10 --retry-delay 5 --silent --disable --fail --retry-all-errors "http://${dashboardIP}:5601/api/saved_objects/_import?overwrite=true" -H 'osd-xsrf: true' -F "file=@$PSScriptRoot/opensearch-dashboard-saved-objects/fluent-bit-index-pattern.ndjson" 2>$null
Write-Log $importingSavedObjects

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'logging' })
Write-Log 'Logging Stack installed successfully'

Write-UsageForUser

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}