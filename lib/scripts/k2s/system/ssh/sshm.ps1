# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Opens a ssh connection with Kubemaster VM. 

.DESCRIPTION
Opens a ssh connection with Kubemaster VM. It can also remotely execute commands in the Kubemaster VM.

.PARAMETER Command
(Optional) Command to be executed in the Kubemaster VM

.EXAMPLE
# Opens a ssh connection with Kubemaster
PS> .\sshm.ps1 

.EXAMPLE
# Runs a command in Kubemaster VM
PS> .\sshm.ps1 -Command "echo hello"
#>

Param(
    [Parameter(Mandatory = $false, HelpMessage = 'Command to be executed in the Kubemaster VM')]
    [string]$Command = ''
)

$infraModule = "$PSScriptRoot/../../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot/../../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule

$systemError = Test-SystemAvailability
if ($systemError) {
    throw $systemError
}

if ([string]::IsNullOrWhitespace($Command)) {
    Invoke-TerminalOnControlPanelViaSSHKey
}
else {
    Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute:$Command
}