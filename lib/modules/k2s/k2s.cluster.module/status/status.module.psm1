# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

$vmModule = "$PSScriptRoot\..\..\k2s.node.module\linuxnode\vm\vm.module.psm1"
$setupInfoModule = "$PSScriptRoot\..\setupinfo\setupinfo.module.psm1"
$runningStateModule = "$PSScriptRoot\..\runningstate\runningstate.v2.module.psm1"
$k8sApiModule = "$PSScriptRoot/../k8s-api/k8s-api.module.psm1"
$infraModule = "$PSScriptRoot/../../k2s.infra.module/k2s.infra.module.psm1"

Import-Module $vmModule, $setupInfoModule, $runningStateModule, $k8sApiModule, $infraModule

$script = $MyInvocation.MyCommand.Name

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
        Write-Progress -Activity 'Gathering status information...' -Id 1 -Status '0/4' -PercentComplete 0 -CurrentOperation 'Getting setup type'
    }

    $setupInfo = Get-SetupInfo
    if ($setupInfo.Error) {
        Write-Log "[$script::$function] Setup type invalid, returning with error='$($setupInfo.Error)'"

        if ($ShowProgress -eq $true) {
            Write-Progress -Activity 'Gathering status information...' -Id 1 -Completed
        }

        $err = New-Error -Severity Warning -Code $setupInfo.Error -Message 'You have not installed K2s setup yet, please install K2s first.'        
        return @{Error = $err }
    }

    $status = @{SetupInfo = $setupInfo }

    if ($ShowProgress -eq $true) {
        Write-Progress -Activity 'Gathering status information...' -Id 1 -Status '1/4' -PercentComplete 25 -CurrentOperation 'Determining running state'
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
        Write-Progress -Activity 'Gathering status information...' -Id 1 -Status '2/4' -PercentComplete 50 -CurrentOperation 'Getting K8s version info'
    }

    $status.K8sVersionInfo = Get-K8sVersionInfo

    if ($ShowProgress -eq $true) {
        Write-Progress -Activity 'Gathering status information...' -Id 1 -Status '3/4' -PercentComplete 75 -CurrentOperation 'Getting K8s nodes info'
    }

    $nodes = [System.Collections.ArrayList]@()
    Get-Nodes | ForEach-Object { $nodes.Add($_) | Out-Null }

    Write-Log "[$script::$function] Added '$($nodes.Count)' nodes to status"

    if ($ShowProgress -eq $true) {
        Write-Progress -Activity 'Gathering status information...' -Id 1 -Status '4/4' -PercentComplete 95 -CurrentOperation 'Getting K8s system pods info'
    }

    $pods = [System.Collections.ArrayList]@()
    Get-SystemPods | ForEach-Object { $pods.Add($_) | Out-Null }

    Write-Log "[$script::$function] Added '$($pods.Count)' pods to status"

    $status.Nodes = $nodes
    $status.Pods = $pods

    if ($ShowProgress -eq $true) {
        Write-Progress -Activity 'Gathering status information...' -Id 1 -Status '4/4' -PercentComplete 100
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

<#
.SYNOPSIS
DEPRECATED: Replace with Test-SystemAvailability eventually when script structure migration is done

.DESCRIPTION
DEPRECATED: Replace with Test-SystemAvailability eventually when script structure migration is done
#>
function Test-ClusterAvailability {
    if (!(Get-IsControlPlaneRunning) -and !(Get-KubernetesServiceAreRunning) ) {
        throw "System is not running. Please start the systeb with 'k2s start'."
    }
}

function Test-SystemAvailability {
    param(
        [Parameter(Mandatory = $false)]
        [switch]
        $Structured = $false # TODO: flag for compatibility reasons; remove when completely migrated
    )
    $setupInfo = Get-SetupInfo
    if ($setupInfo.Error) {
        if ($Structured -eq $true) {
            $err = $err = New-Error -Severity Warning -Code $setupInfo.Error -Message 'You have not installed K2s setup yet, please install K2s first.' 
            return $err
        }
        return $setupInfo.Error
    }

    $state = (Get-RunningState -SetupName $setupInfo.Name)
    if ($state.IsRunning -ne $true) {
        $notRunningErr = Get-ErrCodeSystemNotRunning
        if ($Structured -eq $true) {
            $err = $err = New-Error -Severity Warning -Code $notRunningErr -Message 'K2s is not running. To interact with the system, please start K2s first.' 
            return $err
        }
        return $notRunningErr
    }

    return $null
}

function Get-IsWorkerVM {
    $setupInfo = Get-SetupInfo
    if ($setupInfo.Name -eq 'MultiVMK8s') {
        return $true
    }
    else {
        return $false
    }
}

Export-ModuleMember -Function Get-Status, Get-KubernetesServiceAreRunning, Test-ClusterAvailability, Test-SystemAvailability, Get-IsWorkerVM