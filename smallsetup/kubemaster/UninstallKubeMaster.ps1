# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Remove linux VM acting as KubeMaster

.DESCRIPTION
This script assists in the following actions for Small K8s:
- Remove linux VM
- Remove switch
- Remove virtual disk

.EXAMPLE
PS> .\UninstallKubeMaster.ps1
#>

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
    [Boolean] $DeleteFilesForOfflineInstallation = $false
)

$ErrorActionPreference = 'Continue'
if ($Trace) {
    Set-PSDebug -Trace 1
}

# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1

# import global functions
. $PSScriptRoot\..\common\GlobalFunctions.ps1

# try to remove switch
Remove-KubeSwitch

Write-Log "Remove ip address and nat: $global:SwitchName"
Remove-NetIPAddress -IPAddress $global:IP_NextHop -PrefixLength 24 -Confirm:$False -ErrorAction SilentlyContinue
Remove-NetNatStaticMapping -NatName $global:NetNatName -Confirm:$False -ErrorAction SilentlyContinue
Remove-NetNat -Name $global:NetNatName -Confirm:$False -ErrorAction SilentlyContinue

if ($(Get-WSLFromConfig)) {
    wsl --shutdown | Out-Null
    wsl --unregister $global:VMName | Out-Null
    Reset-DnsServer $global:WSLSwitchName
}
else {
    # remove vm
    Stop-VirtualMachine -VmName $global:VMName -Wait
    Remove-VirtualMachine $global:VMName
}

Write-Log 'Uninstall provisioner of linux node'
& "$global:KubernetesPath\smallsetup\baseimage\Cleaner.ps1"

if ($DeleteFilesForOfflineInstallation) {
    $kubemasterBaseImagePath = Get-KubemasterBaseImagePath
    $kubemasterRootfsPath = Get-KubemasterRootfsPath
    Write-Log "Delete file '$kubemasterBaseImagePath' if existing"
    if (Test-Path $kubemasterBaseImagePath) {
        Remove-Item $kubemasterBaseImagePath -Force
        Remove-Item $kubemasterRootfsPath -Force
    }
}
