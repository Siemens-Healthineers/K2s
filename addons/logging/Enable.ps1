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
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.node.module/k2s.node.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$loggingModule = "$PSScriptRoot\logging.module.psm1"

Import-Module $clusterModule, $infraModule, $addonsModule, $nodeModule, $loggingModule

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

Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo mkdir -m 777 -p /logging'

Write-Log 'Installing fluent-bit and opensearch stack' -Console

# opensearch
# opensearch dashboards
# fluent-bit linux

$manifestsPath = "$PSScriptRoot\manifests"

(Invoke-Kubectl -Params 'apply', '-f', "$manifestsPath\namespace.yaml").Output | Write-Log
(Invoke-Kubectl -Params 'create', '-k', "$manifestsPath\").Output | Write-Log

# fluent-bit windows
$setupInfo = Get-SetupInfo
if ($setupInfo.LinuxOnly -eq $false) {
    (Invoke-Kubectl -Params 'create', '-k', "$manifestsPath\fluentbit\windows").Output | Write-Log
}

Write-Log 'Waiting for pods being ready...' -Console
$kubectlCmd = (Invoke-Kubectl -Params 'rollout', 'status', 'deployments', '-n', 'logging', '--timeout=180s')
Write-Log $kubectlCmd.Output
if (!$kubectlCmd.Success) {
    $errMsg = 'Opensearch dashboards could not be deployed successfully!'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$kubectlCmd = (Invoke-Kubectl -Params 'rollout', 'status', 'statefulsets', '-n', 'logging', '--timeout=180s')
Write-Log $kubectlCmd.Output
if (!$kubectlCmd.Success) {
    $errMsg = 'Opensearch could not be deployed successfully!'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$kubectlCmd = (Invoke-Kubectl -Params 'rollout', 'status', 'daemonsets', '-n', 'logging', '--timeout=180s')
Write-Log $kubectlCmd.Output
if (!$kubectlCmd.Success) {
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
    (Invoke-Kubectl -Params 'apply', '-f', "$manifestsPath\opensearch-dashboards\traefik.yaml").Output | Write-Log
}
Add-HostEntries -Url 'k2s-logging.local'

# Import saved objects 
$dashboardIP = (Invoke-Kubectl -Params 'get', 'pods', '-l=app.kubernetes.io/name=opensearch-dashboards', '-n', 'logging', '-o=jsonpath="{.items[0].status.podIP}"').Output
$dashboardIP = $dashboardIP -replace '"', ""

$importingSavedObjects = curl.exe -X POST --retry 10 --retry-delay 5 --silent --disable --fail --retry-all-errors "http://${dashboardIP}:5601/api/saved_objects/_import?overwrite=true" -H 'osd-xsrf: true' -F "file=@$PSScriptRoot/opensearch-dashboard-saved-objects/syslog-index-pattern.ndjson" 2>$null
Write-Log $importingSavedObjects

$importingSavedObjects = curl.exe -X POST --retry 10 --retry-delay 5 --silent --disable --fail --retry-all-errors "http://${dashboardIP}:5601/api/saved_objects/_import?overwrite=true" -H 'osd-xsrf: true' -F "file=@$PSScriptRoot/opensearch-dashboard-saved-objects/pods-index-pattern.ndjson" 2>$null
Write-Log $importingSavedObjects

$importingSavedObjects = curl.exe -X POST --retry 10 --retry-delay 5 --silent --disable --fail --retry-all-errors "http://${dashboardIP}:5601/api/saved_objects/_import?overwrite=true" -H 'osd-xsrf: true' -F "file=@$PSScriptRoot/opensearch-dashboard-saved-objects/cluster-index-pattern.ndjson" 2>$null
Write-Log $importingSavedObjects

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'logging' })
Write-Log 'Logging Stack installed successfully'

Write-UsageForUser

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}