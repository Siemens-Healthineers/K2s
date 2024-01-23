# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

$pathModule = "$PSScriptRoot\..\..\k2s.infra.module\path\path.module.psm1"
Import-Module $pathModule

$rootConfig = Get-RootConfig

$multivmRootConfig = $rootConfig.psobject.properties['multivm'].value

function Get-RootConfigMultivm {
    return $multivmRootConfig
}

Export-ModuleMember Get-RootConfigMultivm