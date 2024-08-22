# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Cache vSwitches on stop')]
    [switch] $CacheK2sVSwitches,
    [parameter(Mandatory = $false, HelpMessage = 'Skips showing stop header display')]
    [switch] $SkipHeaderDisplay = $false
)

$stopParameters = @{
    ShowLogs = $ShowLogs
    AdditionalHooksDir = $AdditionalHooksDir
    CacheK2sVSwitches = $CacheK2sVSwitches
    SkipHeaderDisplay = $SkipHeaderDisplay
}

& "$PSScriptRoot\..\lib\scripts\k2s\stop\stop.ps1" @stopParameters