# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

$loopbackAdapterModule = "$PSScriptRoot\..\..\..\..\lib\modules\k2s\k2s.node.module\windowsnode\network\loopbackadapter.module.psm1"
$temporaryPathModule = "$PSScriptRoot\still-to-merge.path.module.psm1"

Import-Module $loopbackAdapterModule, $temporaryPathModule


function Get-LoopbackAdapterName {
    return Get-L2BridgeName
}

function Get-LoopbackAdapterIpAddress {
    return Get-LoopbackAdapterIP
}

function Get-LoopbackAdapterGatewayIpAddress {
    return Get-LoopbackAdapterGateway
}

function Get-LoopbackAdapterExecutable {
    return "$(Get-InstallationPath)\bin\devgon.exe"
}

Export-ModuleMember -Function Get-LoopbackAdapterName, Get-LoopbackAdapterIpAddress, Get-LoopbackAdapterGatewayIpAddress, Get-LoopbackAdapterExecutable 
