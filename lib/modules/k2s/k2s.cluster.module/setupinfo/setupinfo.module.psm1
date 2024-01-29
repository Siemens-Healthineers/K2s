# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

Import-Module "$PSScriptRoot/../../k2s.infra.module/config/config.module.psm1"

function Confirm-SetupNameIsValid {
    param (
        [Parameter(Mandatory = $false)]
        [string]$SetupName
    )
    $validationError = switch ( $SetupName ) {
        'k2s' { $null }
        'MultiVMK8s' { $null }
        'BuildOnlyEnv' { $null }
        $null { 'not-installed' }
        '' { 'not-installed' }
        Default { "invalid:'$SetupName'" }
    }
    
    return $validationError
}

function Get-SetupInfo {
    $setupName = Get-ConfigSetupType
    $linuxOnly = (Get-ConfigLinuxOnly) -eq $true
    $validationError = Confirm-SetupNameIsValid -SetupName $setupName
    $productVersion = "v$(Get-ProductVersion)"

    if ($validationError) {
        $linuxOnly = $null
        $productVersion = $null
    }

    return [pscustomobject]@{
        Name            = $setupName; 
        Version         = $productVersion; 
        ValidationError = $validationError; 
        LinuxOnly       = $linuxOnly
    }
}

Export-ModuleMember -Function Get-SetupInfo