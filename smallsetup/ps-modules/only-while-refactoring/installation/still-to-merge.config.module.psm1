# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

$configModule = "$PSScriptRoot\..\..\..\..\lib\modules\k2s\k2s.infra.module\config\config.module.psm1"

Import-Module $configModule

function Get-KubernetesVersion {
    return Get-DefaultK8sVersion
}

function Set-ConfigContainerdFlag {
    param (
        [object] $Value = $(throw 'Please provide the config value.')
    )
    $setupJsonFile = Get-SetupConfigFilePath
    Set-ConfigValue -Path $setupJsonFile -Key 'UseContainerd' -Value $Value
}

function Set-ReuseExistingLinuxComputerForMasterNodeFlag {
    param (
        [object] $Value = $(throw 'Please provide the config value.')
    )
    $setupJsonFile = Get-SetupConfigFilePath
    Set-ConfigValue -Path $setupJsonFile -Key 'ReuseExistingLinuxComputerForMasterNode' -Value $Value
}

# imported functions
Export-ModuleMember -Function Set-ConfigWslFlag, Set-ConfigLinuxOsType, Set-ConfigSetupType 
# new functions
Export-ModuleMember -Function Get-KubernetesVersion, Set-ConfigContainerdFlag, Set-ReuseExistingLinuxComputerForMasterNodeFlag