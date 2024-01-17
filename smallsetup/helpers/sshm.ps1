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

if ($setupInfo.Name -eq $global:SetupType_BuildOnlyEnv) {
    $runningVMs = Get-VM -ErrorAction SilentlyContinue | Where-Object { $_.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running }
    if (! $($runningVMs | Where-Object Name -eq $global:VMName)) {
        throw "VM $global:VMName is not started!"
    }
}
else {
    $clusterState = Get-RunningState -SetupType $setupInfo.Name

    if ($clusterState.IsRunning -ne $true) {
        throw "Cannot connect to master via ssh when cluster is not running. Please start the cluster with 'k2s start'."
    }
}

if (Test-Path $global:LinuxVMKey -PathType Leaf) {
    #Note: DO NOT ADD -n option for ssh.exe
    if ([string]::IsNullOrWhitespace($Command)) {
        ssh.exe -o StrictHostKeyChecking=no -i $global:LinuxVMKey $global:Remote_Master "$(($MyInvocation).UnboundArguments)"
    }
    else {
        ssh.exe -n -o StrictHostKeyChecking=no -i $global:LinuxVMKey $global:Remote_Master "$Command" | ForEach-Object { Write-Output $_ }
    }
}
else {
    Write-Warning "Unable to find ssh directory $global:LinuxVMKey"
}