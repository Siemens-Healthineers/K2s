# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

Import-Module "$PSScriptRoot/../../k2s.infra.module/k2s.infra.module.psm1"

function Confirm-SetupNameIsValid {
    param (
        [Parameter(Mandatory = $false)]
        [string]$SetupName
    )
    $validationError = switch ( $SetupName ) {
        'k2s' { $null }
        'MultiVMK8s' { $null }
        'BuildOnlyEnv' { $null }
        $null { Get-ErrCodeSystemNotInstalled }
        '' { Get-ErrCodeSystemNotInstalled }
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
        $setupName = $null
    }

    return [pscustomobject]@{
        Name      = $setupName; 
        Version   = $productVersion; 
        Error     = $validationError; 
        LinuxOnly = $linuxOnly
    }
}

Export-ModuleMember -Function Get-SetupInfo