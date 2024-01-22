# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$setupInfoModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.cluster.module\setupinfo\setupinfo.module.psm1"
$runningStateModule = "$PSScriptRoot\..\..\smallsetup\status\RunningState.module.psm1"
Import-Module $setupInfoModule, $runningStateModule

<#
.SYNOPSIS
Contains common methods for installing and uninstalling Traefik Ingress Controller in Kubernetes.

#>

function Get-TraefikYamlDir {
    return "$PSScriptRoot\manifests"
}

function Test-ClusterAvailability {
    $setupInfo = Get-SetupInfo
    if ($setupInfo.ValidationError) {
        throw $setupInfo.ValidationError
    }

    $clusterState = Get-RunningState -SetupType $setupInfo.Name

    if ($clusterState.IsRunning -ne $true) {
        throw "Cannot interact with 'traefik' addon when cluster is not running. Please start the cluster with 'k2s start'."
    }  
}