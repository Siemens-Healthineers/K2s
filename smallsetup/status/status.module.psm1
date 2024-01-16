# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

&$PSScriptRoot\..\common\GlobalVariables.ps1
. $PSScriptRoot\..\common\GlobalFunctions.ps1
$addonModule = "$PSScriptRoot/../../addons/Addons.module.psm1"
$k8sApiModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k8s-api/k8s-api.module.psm1"
$logModule = "$PSScriptRoot\..\ps-modules\log\log.module.psm1"
$runningStateModule = "$PSScriptRoot/RunningState.module.psm1"
$setupTypeModule = "$PSScriptRoot/SetupType.module.psm1"

Import-Module $addonModule, $k8sApiModule, $runningStateModule, $setupTypeModule, $logModule

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
        Write-Progress -Activity 'Gathering status information...' -Id 1 -Status '0/5' -PercentComplete 0 -CurrentOperation 'Getting setup type'
    }

    $status = @{SetupType = Get-SetupType }

    if ($status.SetupType.ValidationError) {
        Write-Log "[$script::$function] Setup type invalid, returning with error='$($status.SetupType.ValidationError)'"
        
        if ($ShowProgress -eq $true) {
            Write-Progress -Activity 'Gathering status information...' -Id 1 -Completed
        }
        return $status
    }

    if ($ShowProgress -eq $true) {
        Write-Progress -Activity 'Gathering status information...' -Id 1 -Status '1/5' -PercentComplete 20 -CurrentOperation 'Getting enabled addons'
    }

    $status.EnabledAddons = (Get-EnabledAddons).Addons

    if ($ShowProgress -eq $true) {
        Write-Progress -Activity 'Gathering status information...' -Id 1 -Status '2/5' -PercentComplete 40 -CurrentOperation 'Determining running state'
    }

    $status.RunningState = (Get-RunningState $status.SetupType.Name)

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

Export-ModuleMember -Function Get-Status