# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

Param(
    [Parameter(Mandatory = $false)]
    [string]$Command = ''
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
    throw "Cannot connect to worker via scp when system is not running. Please start the system with 'k2s start'."
}

if (Test-Path $global:WindowsVMKey -PathType Leaf) {
    if ([string]::IsNullOrWhitespace($Command)) {
        ssh.exe -o StrictHostKeyChecking=no -i $global:WindowsVMKey $global:Admin_WinNode "$(($MyInvocation).UnboundArguments)"
    }
    else {
        ssh.exe -n -o StrictHostKeyChecking=no -i $global:WindowsVMKey $global:Admin_WinNode "$Command" | ForEach-Object { Write-Output $_ }
    }
}