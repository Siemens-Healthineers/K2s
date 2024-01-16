# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

&$PSScriptRoot\..\common\GlobalVariables.ps1
. $PSScriptRoot\..\common\GlobalFunctions.ps1

class SetupType {
    [string]$Name
    [string]$Version
    [string]$ValidationError
    [bool]$LinuxOnly
}

function New-SetupType {
    param (
        [Parameter(Mandatory = $false)]
        [string]$Name,
        [Parameter(Mandatory = $false)]
        [string]$Version,
        [Parameter(Mandatory = $false)]
        [string]$ValidationError,
        [Parameter(Mandatory = $false)]
        [bool]$LinuxOnly
    )
    return New-Object SetupType -Property @{Name = $Name; Version = $Version; ValidationError = $ValidationError; LinuxOnly = $LinuxOnly }
}

function Confirm-SetupTypeIsValid {
    param (
        [Parameter(Mandatory = $false)]
        [string]$SetupType
    )
    $validationError = switch ( $SetupType ) {
        $global:SetupType_k2s { $null }
        $global:SetupType_MultiVMK8s { $null }
        $global:SetupType_BuildOnlyEnv { 'There is no cluster installed for build-only ;-)' }
        Default { "You have not installed k2s setup yet, please start installation with command 'k2s install'" }
    }
    
    return $validationError
}

function Get-SetupType {
    $setupType = Get-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_SetupType

    $validationError = Confirm-SetupTypeIsValid $setupType

    $linuxOnly = Get-LinuxOnlyFromConfig

    return New-SetupType -Name $setupType -Version "v$global:ProductVersion" -ValidationError $validationError -LinuxOnly $linuxOnly
}

Export-ModuleMember -Function Get-SetupType, Confirm-SetupTypeIsValid