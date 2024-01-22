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

$setupInfoModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.cluster.module\setupinfo\setupinfo.module.psm1"
$runningStateModule = "$PSScriptRoot\..\status\RunningState.module.psm1"
Import-Module $setupInfoModule, $runningStateModule

$setupInfo = Get-SetupInfo
if (!$($setupInfo.Name)) {
    throw 'No setup installed!'
}

if ($setupInfo.Name -ne $global:SetupType_MultiVMK8s -or $setupInfo.LinuxOnly ) {
    throw 'There is no multi-vm setup with worker node installed.'
}

$clusterState = Get-RunningState -SetupType $setupInfo.Name

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