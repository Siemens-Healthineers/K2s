# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

Import-Module "$PSScriptRoot\..\..\..\..\..\smallsetup\status\status.module.psm1" -Prefix legacy
$vmModule = "$PSScriptRoot\..\..\k2s.node.module\linuxnode\vm\vm.module.psm1"
Import-Module $vmModule

<#
 .Synopsis
  Determines the K8s cluster status.

  .Description
  Gathers status information about the K8s cluster.

  .PARAMETER ShowProgress
  If set to $true, shows the overalls progress on operation-level.

 .Example
  Get-Status

 .Example
  Get-Status -ShowProgress $true

 .OUTPUTS
  Status object
#>
function Get-Status {
    param(
        [Parameter(Mandatory = $false)]
        [bool]
        $ShowProgress = $false
    )
    return Get-legacyStatus -ShowProgress:$ShowProgress
}


function Get-KubernetesServiceAreRunning {
    $servicesToCheck = 'flanneld', 'kubelet', 'kubeproxy', 'containerd'

    foreach ($service in $servicesToCheck) {
        if ((Get-Service -Name $service -ErrorAction SilentlyContinue).Status -ne 'Running') {
            return $false
        }
    }

    return $true
}

function Test-ClusterAvailability {
    if (!(Get-IsControlPlaneRunning) -and !(Get-KubernetesServiceAreRunning) ) {
        throw "Cluster is not running. Please start the cluster with 'k2s start'."
    }
}

Export-ModuleMember -Function Get-Status, Get-KubernetesServiceAreRunning, Test-ClusterAvailability