# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Stops the K8s cluster.

.DESCRIPTION
Stops the K8s cluster and resets networking, file sharing, etc.

.PARAMETER HideHeaders
Specifies whether to hide headers console output, e.g. when script runs in the context of a parent script.

.PARAMETER ShowLogs
Show all logs in terminal

.PARAMETER AdditionalHooksDir
Directory containing additional hooks to be executed after local hooks are executed.

.EXAMPLE
PS> Stop_MultiVMK8sSetup.ps1

.EXAMPLE
PS> Stop_MultiVMK8sSetup.ps1 -HideHeaders $true
Header log entries will not be written/logged to the console.

.EXAMPLE
PS> Stop_MultiVMK8sSetup.ps1 -AdditonalHooks 'C:\AdditionalHooks'
For specifying additional hooks to be executed.
#>

param(
    [parameter(Mandatory = $false, HelpMessage = 'Set to TRUE to omit script headers.')]
    [switch] $HideHeaders = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Stop during uninstallation')]
    [switch] $StopDuringUninstall = $false
)

$stopParameters = @{
    HideHeaders = $HideHeaders
    ShowLogs = $ShowLogs
    AdditionalHooksDir = $AdditionalHooksDir
}

& "$PSScriptRoot\..\..\lib\scripts\multivm\stop\stop.ps1" @stopParameters