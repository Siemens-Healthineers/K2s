# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

$vmModule = "$PSScriptRoot\..\..\k2s.node.module\linuxnode\vm\vm.module.psm1"
$setupInfoModule = "$PSScriptRoot\..\setupinfo\setupinfo.module.psm1"
$runningStateModule = "$PSScriptRoot\..\runningstate\runningstate.v2.module.psm1"
$k8sApiModule = "$PSScriptRoot/../k8s-api/k8s-api.module.psm1"
$logModule = "$PSScriptRoot/../../k2s.infra.module/log/log.module.psm1"

Import-Module $vmModule, $setupInfoModule, $runningStateModule, $k8sApiModule, $logModule

$script = $MyInvocation.MyCommand.Name

function Get-EnabledAddons {
    return (&"$PSScriptRoot/../../../../../addons/Get-EnabledAddons.ps1").Addons 
}

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
    $function = $MyInvocation.MyCommand.Name

    Write-Log "[$script::$function] Getting status with ShowProgress='$ShowProgress'.."

    if ($ShowProgress -eq $true) {
        Write-Progress -Activity 'Gathering status information...' -Id 1 -Status '0/5' -PercentComplete 0 -CurrentOperation 'Getting setup type'
    }

    $status = @{SetupInfo = Get-SetupInfo }

    if ($status.SetupInfo.ValidationError) {
        Write-Log "[$script::$function] Setup type invalid, returning with error='$($status.SetupInfo.ValidationError)'"
        
        if ($ShowProgress -eq $true) {
            Write-Progress -Activity 'Gathering status information...' -Id 1 -Completed
        }
        return $status
    }

    if ($ShowProgress -eq $true) {
        Write-Progress -Activity 'Gathering status information...' -Id 1 -Status '1/5' -PercentComplete 20 -CurrentOperation 'Getting enabled addons'
    }

    # TODO: remove dependency when status and addons are separated!
    # see https://github.com/Siemens-Healthineers/K2s/issues/62
    $status.EnabledAddons = (Get-EnabledAddons)

    if ($ShowProgress -eq $true) {
        Write-Progress -Activity 'Gathering status information...' -Id 1 -Status '2/5' -PercentComplete 40 -CurrentOperation 'Determining running state'
    }

    $status.RunningState = (Get-RunningState $status.SetupInfo.Name)

    if ($status.RunningState.IsRunning -ne $true) {
        Write-Log "[$script::$function] cluster not running, returning"

        if ($ShowProgress -eq $true) {
            Write-Progress -Activity 'Gathering status information...' -Id 1 -Completed
        }
        return $status
    }

    if ($ShowProgress -eq $true) {
        Write-Progress -Activity 'Gathering status information...' -Id 1 -Status '3/5' -PercentComplete 60 -CurrentOperation 'Getting K8s version info'
    }

    $status.K8sVersionInfo = Get-K8sVersionInfo

    if ($ShowProgress -eq $true) {
        Write-Progress -Activity 'Gathering status information...' -Id 1 -Status '4/5' -PercentComplete 80 -CurrentOperation 'Getting K8s nodes info'
    }

    $nodes = [System.Collections.ArrayList]@()
    Get-Nodes | ForEach-Object { $nodes.Add($_) | Out-Null }

    Write-Log "[$script::$function] Added '$($nodes.Count)' nodes to status"

    if ($ShowProgress -eq $true) {
        Write-Progress -Activity 'Gathering status information...' -Id 1 -Status '5/5' -PercentComplete 95 -CurrentOperation 'Getting K8s system pods info'
    }

    $pods = [System.Collections.ArrayList]@()
    Get-SystemPods | ForEach-Object { $pods.Add($_) | Out-Null }

    Write-Log "[$script::$function] Added '$($pods.Count)' pods to status"

    $status.Nodes = $nodes
    $status.Pods = $pods

    if ($ShowProgress -eq $true) {
        Write-Progress -Activity 'Gathering status information...' -Id 1 -Status '5/5' -PercentComplete 100
        Write-Progress -Activity 'Gathering status information...' -Id 1 -Completed
    }

    return $status
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

# Replace with Test-SystemAvailability?
function Test-ClusterAvailability {
    if (!(Get-IsControlPlaneRunning) -and !(Get-KubernetesServiceAreRunning) ) {
        throw "Cluster is not running. Please start the cluster with 'k2s start'."
    }
}

function Test-SystemAvailability {
    $setupInfo = Get-SetupInfo
    if ($setupInfo.ValidationError) {
        return $setupInfo.ValidationError
    }
   
    $state = (Get-RunningState -SetupName $setupInfo.Name)
    if ($state.IsRunning -ne $true) {
        return 'not-running'
    }

    return $null
}

Export-ModuleMember -Function Get-Status, Get-KubernetesServiceAreRunning, Test-ClusterAvailability, Test-SystemAvailability