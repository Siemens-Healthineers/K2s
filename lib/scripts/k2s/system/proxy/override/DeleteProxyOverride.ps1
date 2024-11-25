# SPDX-FileCopyrightText: © 2024 Siemens Healthcare AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $true, HelpMessage = 'Proxy overrides tobe deleted')]
    [string[]] $Overrides,

    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,

    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,

    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$infraModule = "$PSScriptRoot/../../../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"

Import-Module $infraModule, $nodeModule
Initialize-Logging

try {
    Remove-NoProxyEntry -Entries $Overrides
    Stop-WinHttpProxy
    $updatedProxyConfig = Get-ProxyConfig
    Set-ProxyConfigInHttpProxy -Proxy $updatedProxyConfig.HttpProxy -ProxyOverride $updatedProxyConfig.NoProxy
    Start-WinHttpProxy
    if ($EncodeStructuredOutput) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null}
    }
    Write-Log "[$script] finished"

} catch {
    Write-Log "[$script] $($_.Exception.Message) - $($_.ScriptStackTrace)" -Error

    throw $_
}