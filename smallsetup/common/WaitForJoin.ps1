# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
    Wait until both the master and the worker node are ready, then kill the kubeadm process which waits
    for the TLS bootstrap.
    This shortens the waiting time, as we have no real TLS bootstrap:
     - The config file got copied from the master, so the kubelet
       starts and joins without doing a full TLS bootstrap
     - As a consequence, the kubeadm join waits forever and does not detect
       the finished joining
#>


# load global settings
&$PSScriptRoot\GlobalVariables.ps1
. $PSScriptRoot\GlobalFunctions.ps1

Import-Module "$PSScriptRoot/../ps-modules/log/log.module.psm1"

$hostname = Get-ControlPlaneNodeHostname

for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep 2
    #Write-Log "Checking for node $env:COMPUTERNAME..."

    $nodes = $(&$global:KubectlExe get nodes)
    #Write-Log "$i WaitForJoin: $nodes"

    $nodefound = $nodes | Select-String -Pattern "$env:COMPUTERNAME\s*Ready"
    if ( $nodefound ) {
        Write-Log "Node found: $nodefound"
        $masterReady = $nodes | Select-String -Pattern "$hostname\s*Ready"
        if ($masterReady) {
            Write-Log "Master also ready, stopping 'kubeadm join'"
            Stop-Process -Name kubeadm -Force -ErrorAction SilentlyContinue
            break
        }
        else {
            Write-Log "Master not ready yet, keep waiting..."
        }
    }
}

