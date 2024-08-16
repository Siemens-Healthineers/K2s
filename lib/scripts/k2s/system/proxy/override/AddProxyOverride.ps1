# SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $true, HelpMessage = 'Hostnames, Domains, IP addresses or Subnets for which proxy server must not be used.')]
    [string[]] $Overrides,

    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,

    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,

    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$infraModule = "$PSScriptRoot/../../../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"

Import-Module $infraModule

Initialize-Logging

Write-Log "AddProxyOverrides command."