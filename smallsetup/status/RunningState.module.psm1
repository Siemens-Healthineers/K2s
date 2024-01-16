# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

&$PSScriptRoot\..\common\GlobalVariables.ps1
. $PSScriptRoot\..\common\GlobalFunctions.ps1

$logModule = "$PSScriptRoot\..\ps-modules\log\log.module.psm1"

Import-Module $logModule

$script = $MyInvocation.MyCommand.Name

class RunningState {
    [bool]$IsRunning
    [string[]]$Issues
}

function Get-IsWslRunning {
    $function = $MyInvocation.MyCommand.Name

    Write-Log "[$script::$function] detecting if WSL is running.."

    $output = wsl -l --running

    foreach ($line in $output) {
        # CLI session encoding issue; check current encoding with [System.Console]::OutputEncoding
        # optional: remove byte replacement and set encoding with [System.Console]::OutputEncoding = [System.Text.Encoding]::Unicode
        if ($line -replace '\x00', '' -match $global:VMName) {
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
        [string]$Name = $(throw 'VM name not specified')
    )
    return (Get-VM -Name $Name).State
}

function Get-IsVmRunning {
    param (
        [Parameter(Mandatory = $false)]
        [string]$Name = $(throw 'VM name not specified')
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
        [string]$SetupType = $(throw 'Setup type not specified')
    )
    if ($SetupType -ne $global:SetupType_k2s -and $SetupType -ne $global:SetupType_MultiVMK8s) {
        throw "Cannot get running state for invalid setup type '$SetupType'"
    }
    $function = $MyInvocation.MyCommand.Name

    Write-Log "[$script::$function] Getting running state for SetupType='$SetupType'"

    $issues = [System.Collections.ArrayList]@()
    $allRunning = $true

    $isWsl = Get-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_WSL
    if ($isWsl -eq $true) {
        Write-Log "[$script::$function] WSL setup type"

        if ((Get-IsWslRunning) -ne $true) {
            $msg = "'kubemaster' not running (WSL)"
            Write-Log "[$script::$function] $msg"
            $allRunning = $false
            $issues.Add($msg) | Out-Null
        }
        else {
            Write-Log "[$script::$function] kubemaster running"
        }
    }
    else {
        Write-Log "[$script::$function] not WSL setup type"

        if ((Get-IsVmRunning -Name $global:VMName) -ne $true) {            
            $vmState = Get-VmState -Name $global:VMName

            $msg = "'$global:VMName' not running, state is '$vmState' (VM)"

            Write-Log "[$script::$function] $msg"

            $allRunning = $false
            $issues.Add($msg) | Out-Null
        }
        else {
            Write-Log "[$script::$function] '$global:VMName' running"
        }
    }

    switch ($SetupType) {
        $global:SetupType_k2s {
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
        $global:SetupType_MultiVMK8s {
            $linuxOnly = Get-LinuxOnlyFromConfig
            if ($linuxOnly) {
                Write-Log "[$script::$function] is Linux-only, no more checks needed"
                break
            }

            $winVmState = Get-VmState -Name $global:MultiVMWindowsVMName
            if ($winVmState -ne 'Running') {
                $msg = "'$global:MultiVMWindowsVMName' not running, state is '$winVmState' (VM)"

                Write-Log "[$script::$function] $msg"

                $allRunning = $false
                $issues.Add($msg) | Out-Null
            }
            else {
                Write-Log "[$script::$function] '$global:MultiVMWindowsVMName' running"
            }
        }
        Default { 
            Write-Log "[$script::$function] no more state checks needed"
            break 
        }
    }

    Write-Log "[$script::$function] returning with IsRunning='$allRunning' and Issues='$issues'"

    return New-Object RunningState -Property @{IsRunning = $allRunning; Issues = $issues }
}

Export-ModuleMember -Function Get-RunningState