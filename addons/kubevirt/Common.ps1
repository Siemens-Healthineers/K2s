# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$setupTypeModule = "$PSScriptRoot\..\..\smallsetup\status\SetupType.module.psm1"
$runningStateModule = "$PSScriptRoot\..\..\smallsetup\status\RunningState.module.psm1"
Import-Module $setupTypeModule, $runningStateModule

function Test-ClusterAvailability {
    $setupType = Get-SetupType
    if ($setupType.ValidationError) {
        throw $setupType.ValidationError
    }

    $clusterState = Get-RunningState -SetupType $setupType.Name

    if ($clusterState.IsRunning -ne $true) {
        throw "Cannot interact with 'kubevirt' addon when cluster is not running. Please start the cluster with 'k2s start'."
    }  
}