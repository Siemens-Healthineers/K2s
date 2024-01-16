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

$setupTypeModule = "$PSScriptRoot\..\status\SetupType.module.psm1"
$runningStateModule = "$PSScriptRoot\..\status\RunningState.module.psm1"
Import-Module $setupTypeModule, $runningStateModule

$setupType = Get-SetupType
if (!$($setupType.Name)) {
    throw 'No setup installed!'
}

if ($setupType.Name -ne $global:SetupType_MultiVMK8s -or $setupType.LinuxOnly ) {
    throw 'There is no multi-vm setup with worker node installed.'
}

$clusterState = Get-RunningState -SetupType $setupType.Name

if ($clusterState.IsRunning -ne $true) {
    throw "Cannot connect to worker via scp when cluster is not running. Please start the cluster with 'k2s start'."
} 

if (Test-Path $global:WindowsVMKey -PathType Leaf) {
    if (!$Reverse) {
        $source = $Source
        $target = $global:Admin_WinNode + ':' + $Target
    }
    else {
        $source = $global:Admin_WinNode + ':' + $Source
        $target = $Target
    }
    
    scp.exe -r -q -o StrictHostKeyChecking=no -i $global:WindowsVMKey $source $target
}
else {
    Write-Warning "Unable to find ssh directory $global:WindowsVMKey"
}