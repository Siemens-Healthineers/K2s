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

if ($setupType.Name -eq $global:SetupType_BuildOnlyEnv) {
    $runningVMs = Get-VM -ErrorAction SilentlyContinue | Where-Object { $_.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running }
    if (! $($runningVMs | Where-Object Name -eq $global:VMName)) {
        throw "VM $global:VMName is not started!"
    }
}
else {
    $clusterState = Get-RunningState -SetupType $setupType.Name

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