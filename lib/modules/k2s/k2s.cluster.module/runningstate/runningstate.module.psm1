# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

$infraModule = "$PSScriptRoot/../../k2s.infra.module/k2s.infra.module.psm1"

Import-Module $infraModule

$script = $MyInvocation.MyCommand.Name

function Get-IsWslRunning {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $Name = $(throw 'Name not specified')
    )
    $function = $MyInvocation.MyCommand.Name

    Write-Log "[$script::$function] detecting if WSL is running.."

    $output = wsl -l --running

    foreach ($line in $output) {
        # CLI session encoding issue; check current encoding with [System.Console]::OutputEncoding
        # optional: remove byte replacement and set encoding with [System.Console]::OutputEncoding = [System.Text.Encoding]::Unicode
        if ($line -replace '\x00', '' -match $Name) {
            Write-Log "[$script::$function] WSL is running"
            return $true
        }
    }

    Write-Log "[$script::$function] WSL not running"

    return $false
}

function Get-VmState {
    param (
        [Parameter(Mandatory = $false)]
        [string]$Name = $(throw 'Name not specified')
    )
    return (Get-VM -Name $Name).State
}

function Get-IsVmRunning {
    param (
        [Parameter(Mandatory = $false)]
        [string]$Name = $(throw 'Name not specified')
    )
    $function = $MyInvocation.MyCommand.Name

    Write-Log "[$script::$function] Checking if VM is running for Name='$Name'.."

    $vmState = Get-VmState -Name $Name

    Write-Log "[$script::$function] Found VM state '$vmState'"

    return $vmState -eq [Microsoft.HyperV.PowerShell.VMState]::Running
}

function Get-RunningState {
    param (
        [Parameter(Mandatory = $false)]
        [string]$SetupName = $(throw 'SetupName not specified')
    )
    if ($SetupName -ne 'k2s' -and $SetupName -ne 'MultiVMK8s' -and $SetupName -ne 'BuildOnlyEnv') {
        throw "cannot get running state for invalid setup type '$SetupName'"
    }

    $function = $MyInvocation.MyCommand.Name

    Write-Log "[$script::$function] Getting running state for SetupType='$SetupName'"

    $issues = [System.Collections.ArrayList]@()
    $allRunning = $true

    $controlPlaneNodeName = Get-ConfigControlPlaneNodeHostname
    $isWsl = Get-ConfigWslFlag

    if ($isWsl -eq $true) {
        Write-Log "[$script::$function] WSL setup type"

        if ((Get-IsWslRunning -Name $controlPlaneNodeName) -ne $true) {
            $msg = "control-plane '$controlPlaneNodeName' not running (WSL)"
            Write-Log "[$script::$function] $msg"
            $allRunning = $false
            $issues.Add($msg) | Out-Null
        }
        else {
            Write-Log "[$script::$function] control-plane '$controlPlaneNodeName' running"
        }
    }
    else {
        Write-Log "[$script::$function] not WSL setup type"

        if ((Get-IsVmRunning -Name $controlPlaneNodeName) -ne $true) {            
            $vmState = Get-VmState -Name $controlPlaneNodeName

            $msg = "control-plane '$controlPlaneNodeName' not running, state is '$vmState' (VM)"

            Write-Log "[$script::$function] $msg"

            $allRunning = $false
            $issues.Add($msg) | Out-Null
        }
        else {
            Write-Log "[$script::$function] control-plane '$controlPlaneNodeName' running"
        }
    }

    switch ($SetupName) {
        'k2s' {
            $servicesToCheck = 'flanneld', 'kubelet', 'kubeproxy'
            foreach ($service in $servicesToCheck) {
                Write-Log "[$script::$function] checking '$service' service state.."

                if ((Get-Service -Name $service -ErrorAction SilentlyContinue).Status -ne 'Running') {
                    $msg = "'$service' not running (service)"

                    Write-Log "[$script::$function] $msg"

                    $allRunning = $false
                    $issues.Add($msg) | Out-Null
                }
                else {
                    Write-Log "[$script::$function] '$service' running"
                }
            }
        }
        'MultiVMK8s' {
            $linuxOnly = Get-ConfigLinuxOnly
            if ($linuxOnly) {
                Write-Log "[$script::$function] is Linux-only, no more checks needed"
                break
            }

            $winWorkerNodeName = Get-ConfigVMNodeHostname
            $winVmState = Get-VmState -Name $winWorkerNodeName
            if ($winVmState -ne 'Running') {
                $msg = "worker node '$winWorkerNodeName' not running, state is '$winVmState' (VM)"

                Write-Log "[$script::$function] $msg"

                $allRunning = $false
                $issues.Add($msg) | Out-Null
            }
            else {
                Write-Log "[$script::$function] worker node '$winWorkerNodeName' running"
            }
        }
        Default { 
            Write-Log "[$script::$function] no more state checks needed"
            break 
        }
    }

    Write-Log "[$script::$function] returning with IsRunning='$allRunning' and Issues='$issues'"

    return @{IsRunning = $allRunning; Issues = $issues }
}

Export-ModuleMember -Function Get-RunningState