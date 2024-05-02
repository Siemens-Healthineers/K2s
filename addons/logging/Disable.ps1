# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Disables logging features for the k2s cluster.

.DESCRIPTION
The logging addon collects all logs from containers/pods running inside the k2s cluster.
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.node.module/k2s.node.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"

Import-Module $clusterModule, $infraModule, $addonsModule, $nodeModule

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

Write-Log 'Check whether logging addon is already disabled'

if ($null -eq (Invoke-Kubectl -Params 'get', 'namespace', 'logging', '--ignore-not-found').Output -and (Test-IsAddonEnabled -Name 'logging') -ne $true) {
    $errMsg = "Addon 'logging' is already disabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyDisabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Uninstalling Logging Stack' -Console

$manifestsPath = "$PSScriptRoot\manifests"

(Invoke-Kubectl -Params 'delete', '-k', $manifestsPath, '--ignore-not-found', '--wait=false').Output | Write-Log
(Invoke-Kubectl -Params 'delete', '-k', "$manifestsPath\fluentbit\windows", '--ignore-not-found', '--wait=false').Output | Write-Log

(Invoke-Kubectl -Params 'delete', 'pod', '-l', 'app.kubernetes.io/name=opensearch-dashboards', '-n', 'logging', '--grace-period=0', '--force', '--ignore-not-found').Output | Write-Log
(Invoke-Kubectl -Params 'delete', 'pod', '-l', 'app.kubernetes.io/name=opensearch', '-n', 'logging', '--grace-period=0', '--force', '--ignore-not-found').Output | Write-Log
(Invoke-Kubectl -Params 'delete', 'pod', '-l', 'app.kubernetes.io/name=fluent-bit', '-n', 'logging', '--grace-period=0', '--force', '--ignore-not-found').Output | Write-Log

if ($PSVersionTable.PSVersion.Major -gt 5) {
    (Invoke-Kubectl -Params 'patch', 'pv', 'opensearch-cluster-master-pv', '-n', 'logging', '-p', '{"metadata":{"finalizers":null}}').Output | Write-Log
    (Invoke-Kubectl -Params 'patch', 'pvc', 'opensearch-cluster-master-opensearch-cluster-master-0', '-n', 'logging', '-p', '{"metadata":{"finalizers":null}}').Output | Write-Log
} else {
    (Invoke-Kubectl -Params 'patch', 'pv', 'opensearch-cluster-master-pv', '-n', 'logging', '-p', '{\"metadata\":{\"finalizers\":null}}').Output | Write-Log
    (Invoke-Kubectl -Params 'patch', 'pvc', 'opensearch-cluster-master-opensearch-cluster-master-0', '-n', 'logging', '-p', '{\"metadata\":{\"finalizers\":null}}').Output | Write-Log
}

(Invoke-Kubectl -Params 'delete', 'namespace', 'logging', '--grace-period=0').Output | Write-Log

Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo rm -rf /logging'

Remove-AddonFromSetupJson -Name 'logging'

Write-Log 'Logging Stack uninstalled successfully' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}