# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

$logModule = "$PSScriptRoot\..\..\k2s.infra.module\log\log.module.psm1"

Import-Module $logModule

<#
.SYNOPSIS
    Stops a given VM
.DESCRIPTION
    Stops a given VM specified by name and waits for the VM to be stopped, if desired.
.PARAMETER VmName
    Name of the VM to stop
.PARAMETER Wait
    If set to TRUE, the function waits for the VM to reach the 'off' state.
.EXAMPLE
    Stop-VirtualMachine -VmName "Test-VM"
.EXAMPLE
    Stop-VirtualMachine -VmName "Test-VM" -Wait
    Waits for the VM to reach the 'off' state.
.NOTES
    The underlying function thrown an exception when the wait timeout is reached.
#>
function Stop-VirtualMachine {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $VmName = $(throw 'Please specify the VM you want to stop.'),
        [Parameter(Mandatory = $false)]
        [Switch]$Wait = $false
    )

    $private:vm = Get-VM | Where-Object Name -eq $VmName

    if (($private:vm | Measure-Object).Count -ne 1) {
        Write-Log "None or more than one VMs found for name '$VmName', aborting stop."
        return
    }

    Write-Log "Stopping VM '$VmName' ..."

    Stop-VM -Name $VmName -Force -WarningAction SilentlyContinue

    if ($Wait -eq $true) {
        Wait-ForDesiredVMState -VmName $VmName -State 'off'
    }

    Write-Log "VM '$VmName' stopped."
}

<#
.SYNOPSIS
    Removes a given VM completely
.DESCRIPTION
    Removes a given VM and it's virtual disk if desired.
.PARAMETER VmName
    Name of the VM to remove
.PARAMETER DeleteVirtualDisk
    Indicating whether the VM's virtual disk should be removed as well (default: TRUE).
.EXAMPLE
    Remove-VirtualMachine -VmName "Test-VM"
    Deletes the VM and it's virtual disk
.EXAMPLE
    Remove-VirtualMachine -VmName "Test-VM" -DeleteVirtualDisk $false
    Deletes the VM but not it's virtual disk
#>
function Remove-VirtualMachine {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $VmName = $(throw 'Please specify the VM you want to remove.'),
        [Parameter()]
        [bool] $DeleteVirtualDisk = $true
    )

    $private:vm = Get-VM | Where-Object Name -eq $VmName

    if (($private:vm | Measure-Object).Count -ne 1) {
        Write-Log "None or more than one VMs found for name '$VmName', aborting removal."
        return
    }

    if ($DeleteVirtualDisk) {
        Remove-VMSnapshots -Vm $private:vm
    }

    $hardDiskPath = ($private:vm | Select-Object -ExpandProperty HardDrives).Path

    Write-Log "Removing VM '$VmName' ($($private:vm.VMId)) ..."
    Remove-VM -Name $VmName -Force
    Write-Log "VM '$VmName' removed."

    if ($DeleteVirtualDisk) {
        Write-Log "Removing hard disk '$hardDiskPath' ..."

        Remove-Item -Path $hardDiskPath -Force

        Write-Log "Hard disk '$hardDiskPath' removed."
    }
    else {
        Write-Log "Keeping virtual disk '$hardDiskPath'."
    }
}

<#
.SYNOPSIS
    Removes all snapshots of a given VM
.DESCRIPTION
    Removes all snapshots of a given VM and waits for the virtual disks to merge
.PARAMETER Vm
    The VM of which the snapshots shall be removed
.EXAMPLE
    $vm = Get-VM | Where-Object Name -eq "my-VM"
    Remove-VMSnapshots -Vm $vm
#>
function Remove-VMSnapshots {
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [Microsoft.HyperV.PowerShell.VirtualMachine] $Vm = $(throw 'Please specify the VM of which you want to remove the snapshots.')
    )

    Write-Log 'Removing VM snapshots ...'

    Get-VMSnapshot -VMName $Vm.Name | Remove-VMSnapshot

    Write-Log 'Waiting for disks to merge ...'

    while ($Vm.Status -eq 'merging disks') {
        Write-Log '.'

        Start-Sleep -Milliseconds 500
    }

    # give the VM object time to refresh it's virtual disk path property
    Start-Sleep -Milliseconds 500

    Write-Log ''
    Write-Log 'VM snapshots removed.'
}

<#
.SYNOPSIS
    Waits for a given VM to get into a given state.
.DESCRIPTION
    Waits for a given VM to get into a given state. The timeout is configurable.
.PARAMETER VmName
    Name of the VM to wait for
.PARAMETER State
    Desired state
.PARAMETER TimeoutInSeconds
    Timeout in seconds. Default is 360.
.EXAMPLE
    Wait-ForDesiredVMState -VmName 'Test-VM' -State 'off'
    Waits for the VM to be shut down.
.EXAMPLE
    Wait-ForDesiredVMState -VmName 'Test-VM' -TimeoutInSeconds 30 -State 'off'
    Wait max. 30 seconds until the VM must be shut down.
.NOTES
    Throws exception if VM was not found or more than one VMs with the given name exist.
    Throws exception if the desired state is invalid. State names are checked case-insensitive.
#>
function Wait-ForDesiredVMState {
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $VmName = $(throw 'Please specify the VM you want to wait for.'),
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $State = $(throw 'Please specify the desired VM state.'),
        [Parameter(Mandatory = $false)]
        [int]$TimeoutInSeconds = 360
    )

    $secondsIncrement = 1
    $elapsedSeconds = 0

    if ([System.Enum]::GetValues([Microsoft.HyperV.PowerShell.VMState]) -notcontains $State) {
        throw "'$State' is an invalid VM state!"
    }

    Write-Log "Waiting for VM '$VmName' to be in state '$State' (timeout: $($TimeoutInSeconds)s) ..."

    $private:vm = Get-VM | Where-Object Name -eq $VmName

    if (($private:vm | Measure-Object).Count -ne 1) {
        throw "None or more than one VMs found for name '$VmName', aborting!"
    }

    while (($private:vm.State -ne $State) -and ($elapsedSeconds -lt $TimeoutInSeconds)) {
        Start-Sleep -Seconds $secondsIncrement

        $elapsedSeconds += $secondsIncrement

        Write-Log "$($elapsedSeconds)s.." -Progress
    }

    if ( $elapsedSeconds -gt 0) {
        Write-Log '.' -Progress
    }

    if ($elapsedSeconds -ge $TimeoutInSeconds) {
        throw "VM '$VmName' did'nt reach the desired state '$State' within the time frame of $($TimeoutInSeconds)s!"
    }
}

Export-ModuleMember Stop-VirtualMachine, Remove-VirtualMachine, Remove-VMSnapshots, Wait-ForDesiredVMState