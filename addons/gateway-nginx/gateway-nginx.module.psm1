# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$setupModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/setupinfo/setupinfo.module.psm1"
$nodeModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.node.module/k2s.node.module.psm1"

Import-Module $infraModule, $setupModule, $nodeModule

function Add-GatewayHostEntry {
    Write-Log 'Configuring nodes access' -Console
  
    # Enable gateway access on linux node
    $hostEntry = "$(Get-ConfiguredIPControlPlane) k2s-gateway.local"
    Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "grep -qxF `'$hostEntry`' /etc/hosts || echo $hostEntry | sudo tee -a /etc/hosts"
  
    # In case of multi-vm, enable access on windows node
    $setupInfo = Get-SetupInfo
    if ($setupInfo.Name -eq 'MultiVMK8s' -and $setupInfo.LinuxOnly -ne $true) {
        $session = Open-DefaultWinVMRemoteSessionViaSSHKey
  
        Invoke-Command -Session $session {
            Set-Location "$env:SystemDrive\k"
            Set-ExecutionPolicy Bypass -Force -ErrorAction Stop
  
            if (!$(Get-Content 'C:\Windows\System32\drivers\etc\hosts' | ForEach-Object { $_ -match $using:hostEntry }).Contains($true)) {
                Add-Content 'C:\Windows\System32\drivers\etc\hosts' $using:hostEntry
            }
        }
    }
  
    # finally, add entry in the host to be enable access
    if (!$(Get-Content 'C:\Windows\System32\drivers\etc\hosts' | ForEach-Object { $_ -match $hostEntry }).Contains($true)) {
        Add-Content 'C:\Windows\System32\drivers\etc\hosts' $hostEntry
    }
}