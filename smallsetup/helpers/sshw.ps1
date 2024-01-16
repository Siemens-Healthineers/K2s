# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

Param(
    [Parameter(Mandatory = $false)]
    [string]$Command = ''
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
    if ([string]::IsNullOrWhitespace($Command)) {
        ssh.exe -o StrictHostKeyChecking=no -i $global:WindowsVMKey $global:Admin_WinNode "$(($MyInvocation).UnboundArguments)"
    }
    else {
        ssh.exe -n -o StrictHostKeyChecking=no -i $global:WindowsVMKey $global:Admin_WinNode "$Command" | ForEach-Object { Write-Output $_ }
    }
}