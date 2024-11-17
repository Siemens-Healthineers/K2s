# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Uninstalls nginx kubernetes gateway controller

.DESCRIPTION
Uninstalls nginx kubernetes gateway controller
#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"

Import-Module $clusterModule, $infraModule, $addonsModule

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

if ($null -eq (Invoke-Kubectl -Params 'get', 'namespace', 'gateway-api', '--ignore-not-found').Output -and (Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'gateway-api' })) -ne $true) {
    $errMsg = "Addon 'gateway-api' is already disabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyDisabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

$manifestsPath = "$(Get-KubePath)\addons\gateway-api\manifests"

Write-Log 'Uninstalling NGINX Kubernetes Gateway Controller' -Console
(Invoke-Kubectl -Params 'delete', '-f', "$manifestsPath\nginx-gateway-fabric-v1.1.0.yaml").Output | Write-Log
(Invoke-Kubectl -Params 'delete', '-f', "$manifestsPath\crds").Output | Write-Log

Write-Log 'Uninstalling Gateway API' -Console
(Invoke-Kubectl -Params 'delete', '-f', "$manifestsPath\gateway-api-v1.0.0.yaml").Output | Write-Log

Remove-ScriptsFromHooksDir -ScriptNames @(Get-ChildItem -Path "$PSScriptRoot\hooks" | ForEach-Object { $_.Name })
Remove-AddonFromSetupJson -Addon ([pscustomobject] @{Name = 'gateway-api' })

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}