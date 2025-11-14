# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $true, HelpMessage = 'Proxy server URL to be used by k2s')]
    [string] $Uri,

    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,

    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,

    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$infraModule = "$PSScriptRoot/../../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"

Import-Module $infraModule, $nodeModule
Initialize-Logging

try {
    Set-ProxyServer -Proxy $Uri
    Stop-WinHttpProxy
    $updatedProxyConfig = Get-ProxyConfig
    
    $k2sHosts = Get-K2sHosts
    $allNoProxyHosts = @()
    if ($updatedProxyConfig.NoProxy.Count -gt 0) {
        $allNoProxyHosts += $updatedProxyConfig.NoProxy
    }
    $allNoProxyHosts += $k2sHosts
    $uniqueNoProxyHosts = $allNoProxyHosts | Sort-Object -Unique
    
    Set-ProxyConfigInHttpProxy -Proxy $updatedProxyConfig.HttpProxy -ProxyOverrides $uniqueNoProxyHosts
    Start-WinHttpProxy
    if ($EncodeStructuredOutput) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null}
    }
    Write-Log "[$script] finished"
} catch {
    Write-Log "[$script] $($_.Exception.Message) - $($_.ScriptStackTrace)" -Error

    throw $_
}