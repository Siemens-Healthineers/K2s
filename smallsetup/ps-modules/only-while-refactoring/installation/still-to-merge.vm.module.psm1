# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

$vmModule = "$PSScriptRoot\..\..\..\..\lib\modules\k2s\k2s.node.module\linuxnode\vm\vm.module.psm1"

Import-Module $vmModule


function Get-LinuxOsType_UsingModule($LinuxVhdxPath) {
    return Get-LinuxOsType($LinuxVhdxPath) 
}

function Get-ControlPlaneVmName {
    return 'KubeMaster'
}


Export-ModuleMember -Function Get-LinuxOsType_UsingModule, Get-ControlPlaneVmName