# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

Import-Module "$PSScriptRoot/../../k2s.infra.module/k2s.infra.module.psm1"

class SetupType {
    [string]$Name
    [string]$Version
    [string]$ValidationError
}

function New-SetupType {
    param (
        [Parameter(Mandatory = $false)]
        [string]$Name,
        [Parameter(Mandatory = $false)]
        [string]$Version,
        [Parameter(Mandatory = $false)]
        [string]$ValidationError
    )
    return New-Object SetupType -Property @{Name = $Name; Version = $Version; ValidationError = $ValidationError}
}

function Get-SetupType {
    $setupFilePath = Get-SetupConfigFilePath
    $setupType = Get-ConfigValue -Path $setupFilePath -Key 'SetupType'

    $validationError = ""
    $productVersion = Get-ProductVersion

    return New-SetupType -Name $setupType -Version "v$productVersion" -ValidationError $validationError
}

Export-ModuleMember -Function Get-SetupType