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
PS> .\lib\scripts\multivm\stop\Stop.ps1

.EXAMPLE
PS> .\lib\scripts\multivm\stop\Stop.ps1 -HideHeaders $true
Header log entries will not be written/logged to the console.

.EXAMPLE
PS> .\lib\scripts\multivm\stop\Stop.ps1 -AdditonalHooks 'C:\AdditionalHooks'
For specifying additional hooks to be executed.
#>

param(
    [parameter(Mandatory = $false, HelpMessage = 'Set to TRUE to omit script headers.')]
    [switch] $HideHeaders = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = ''
)

$infraModule = "$PSScriptRoot\..\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

$ErrorActionPreference = 'Continue'

if ($HideHeaders -eq $false) {
    Write-Log 'Stopping MultiVM K2s'
}

Invoke-Hook -HookName 'BeforeStopK8sNetwork' -AdditionalHooksDir $AdditionalHooksDir

if ($(Get-ConfigLinuxOnly) -eq $false) {
    $workerNodeParams = @{
        HideHeaders = $HideHeaders
        ShowLogs = $ShowLogs
        AdditionalHooksDir = $AdditionalHooksDir
    }
    & "$PSScriptRoot\..\..\worker-node\windows\hyper-v-vm\Stop.ps1" @workerNodeParams
}

Invoke-Hook -HookName 'AfterStopK8sNetwork' -AdditionalHooksDir $AdditionalHooksDir

$controlPlaneParams = " -AdditionalHooksDir `"$AdditionalHooksDir`""
if ($HideHeaders.IsPresent) {
    $controlPlaneParams += " -SkipHeaderDisplay"
}
if ($ShowLogs.IsPresent) {
    $controlPlaneParams += " -ShowLogs"
}
& powershell.exe "$PSScriptRoot\..\..\control-plane\Stop.ps1" $controlPlaneParams

if ($HideHeaders -eq $false) {
    Write-Log 'K2s MultiVM stopped.'
}
