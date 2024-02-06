# SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $true, HelpMessage = 'Loop count')]
    [int] $Count
)

&$PSScriptRoot\..\common\GlobalVariables.ps1
. $PSScriptRoot\..\common\GlobalFunctions.ps1

$loggingModule = "$PSScriptRoot\..\ps-modules\log\log.module.psm1"
Import-Module $loggingModule
Initialize-Logging -ShowLogs:$true

# Create loopback adapter
Import-Module "$global:KubernetesPath\smallsetup\LoopbackAdapter.psm1" -Force
Import-Module "$global:KubernetesPath\smallsetup\hns.v2.psm1" -WarningAction:SilentlyContinue -Force
New-LoopbackAdapter -Name $global:LoopbackAdapter -DevConExe $global:DevconExe | Out-Null

Start-Sleep 1

for ($i = 0; $i -lt $Count; $i++) {
    Write-Log "########################################################### $($i+1) ###########################################################"

    # create l2bridge
    Enable-NetAdapter -Name $global:LoopbackAdapter -Confirm:$false -ErrorAction SilentlyContinue
    Set-LoopbackAdapterProperties -Name $global:LoopbackAdapter -IPAddress $global:IP_LoopbackAdapter -Gateway $global:Gateway_LoopbackAdapter
    CreateExternalSwitch -adapterName $global:LoopbackAdapter

    Get-NetConnectionProfile -interfacealias "vEthernet ($global:LoopbackAdapter)" -ErrorAction SilentlyContinue
    if (!$?) {
        throw "NetConnectionProfile 'vEthernet ($global:LoopbackAdapter)' not found!"
    }

    # remove l2bridge
    RemoveExternalSwitch
    $hns = $(Get-HNSNetwork)
    if ($($hns | Measure-Object).Count -ge 2) {
        Write-Log 'Delete bridge, clear HNSNetwork (short disconnect expected)'
        $hns | Where-Object Name -Like '*cbr0*' | Remove-HNSNetwork -ErrorAction SilentlyContinue
        $hns | Where-Object Name -Like ('*' + $global:SwitchName + '*') | Remove-HNSNetwork -ErrorAction SilentlyContinue
    }

    Get-HnsPolicyList | Remove-HnsPolicyList -ErrorAction SilentlyContinue
    Disable-NetAdapter -Name $global:LoopbackAdapter -Confirm:$false -ErrorAction SilentlyContinue
} 

Remove-LoopbackAdapter -Name $global:LoopbackAdapter -DevConExe $global:DevconExe


