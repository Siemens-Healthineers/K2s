# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$hookFilePaths = @()
$hookFilePaths += Get-ChildItem -Path "$PSScriptRoot\hooks" | ForEach-Object { $_.FullName }
$hookFileNames = @()
$hookFileNames += Get-ChildItem -Path "$PSScriptRoot\hooks" | ForEach-Object { $_.Name }

Import-Module "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/setupinfo/setupinfo.module.psm1"

<#
.DESCRIPTION
Adds an entry in hosts file for k2s-gateway.local in both the windows and linux nodes
#>
function Add-GatewayHostEntry {
    Write-Log 'Configuring nodes access' -Console
    $gatewayIP = $global:IP_Master
    $gatewayHost = 'k2s-gateway.local'
  
    # Enable gateway access on linux node
    $hostEntry = $($gatewayIP + ' ' + $gatewayHost)
    ExecCmdMaster "grep -qxF `'$hostEntry`' /etc/hosts || echo $hostEntry | sudo tee -a /etc/hosts"
  
    # In case of multi-vm, enable access on windows node
    $setupInfo = Get-SetupInfo
    if ($setupInfo.Name -eq $global:SetupType_MultiVMK8s -and $setupInfo.LinuxOnly -ne $true) {
        $session = Open-RemoteSessionViaSSHKey $global:Admin_WinNode $global:WindowsVMKey
  
        Invoke-Command -Session $session {
            Set-Location "$env:SystemDrive\k"
            Set-ExecutionPolicy Bypass -Force -ErrorAction Stop
  
            if (!$(Get-Content 'C:\Windows\System32\drivers\etc\hosts' | % { $_ -match $using:hostEntry }).Contains($true)) {
                Add-Content 'C:\Windows\System32\drivers\etc\hosts' $using:hostEntry
            }
        }
    }
  
    # finally, add entry in the host to be enable access
    if (!$(Get-Content 'C:\Windows\System32\drivers\etc\hosts' | % { $_ -match $hostEntry }).Contains($true)) {
        Add-Content 'C:\Windows\System32\drivers\etc\hosts' $hostEntry
    }
}
  
  