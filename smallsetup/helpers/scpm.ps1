# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

Param(
    [parameter(Mandatory = $false)]
    [string] $Source,
    [parameter(Mandatory = $false)]
    [string] $Target,
    [parameter(Mandatory = $false)]
    [switch] $Reverse
)

&$PSScriptRoot\..\common\GlobalVariables.ps1
. $PSScriptRoot\..\common\GlobalFunctions.ps1

$setupTypeModule = "$PSScriptRoot\..\status\SetupType.module.psm1"
$runningStateModule = "$PSScriptRoot\..\status\RunningState.module.psm1"
Import-Module $setupTypeModule, $runningStateModule

$setupType = Get-SetupType
if (!$($setupType.Name)) {
    throw 'No setup installed!'
}

if ($setupType.Name -eq $global:SetupType_BuildOnlyEnv) {
    $runningVMs = Get-VM -ErrorAction SilentlyContinue | Where-Object { $_.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running }
    if (! $($runningVMs | Where-Object Name -eq $global:VMName)) {
        throw "VM $global:VMName is not started!"
    }
}
else {
    $clusterState = Get-RunningState -SetupType $setupType.Name

    if ($clusterState.IsRunning -ne $true) {
        throw "Cannot connect to master via scp when cluster is not running. Please start the cluster with 'k2s start'."
    } 
}

if (!$Reverse) {
    $source = $Source
    $target = $global:Remote_Master + ':' + $Target
}
else {
    $source = $global:Remote_Master + ':' + $Source
    $target = $Target
}

Copy-FromToMaster $source $target -IgnoreErrors