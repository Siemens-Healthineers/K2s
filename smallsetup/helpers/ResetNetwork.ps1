# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

&$PSScriptRoot\..\common\GlobalVariables.ps1

Write-Output "Removing HNS Network"
Import-Module "$global:KubernetesPath\smallsetup\LoopbackAdapter.psm1" -Force
Get-NetAdapter | Where-Object InterfaceDescription -like 'Microsoft KM-TEST Loopback Adapter*' | ForEach-Object { Remove-LoopbackAdapter -Name $_.Name -DevConExe $global:DevconExe }

Get-HnsNetwork | Remove-HnsNetwork
Write-Output "Delete Network Configuration"
netcfg -d

Write-Output "Restarting Computer"
Restart-Computer -Confirm