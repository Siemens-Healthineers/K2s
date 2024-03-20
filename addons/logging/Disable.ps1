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

Write-Log 'Check whether logging addon is already disabled'

if ($null -eq (&$global:KubectlExe get namespace logging --ignore-not-found) -or (Test-IsAddonEnabled -Name 'logging') -ne $true) {
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

&$global:KubectlExe delete -k "$global:KubernetesPath\addons\logging\manifests"

&$global:KubectlExe patch pv opensearch-cluster-master-pv -n logging -p '{\"metadata\":{\"finalizers\":null}}'
&$global:KubectlExe patch pvc opensearch-cluster-master-opensearch-cluster-master-0 -n logging -p '{\"metadata\":{\"finalizers\":null}}'

&$global:KubectlExe delete -f "$global:KubernetesPath\addons\logging\manifests\namespace.yaml"

ExecCmdMaster 'sudo rm -rf /logging'

Remove-AddonFromSetupJson -Name 'logging'

Write-Log 'Logging Stack uninstalled successfully' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}