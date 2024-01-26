# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

Import-Module "$PSScriptRoot/../../k2s.infra.module/config/config.module.psm1"

function Confirm-SetupTypeIsValid {
    param (
        [Parameter(Mandatory = $false)]
        [string]$SetupType
    )
    $validationError = switch ( $SetupType ) {
        'k2s' { $null }
        'MultiVMK8s' { $null }
        'BuildOnlyEnv' { 'no-cluster' }
        Default { 'not-installed' }
    }
    
    return $validationError
}

function Get-SetupInfo {
    $setupType = Get-ConfigSetupType
    $linuxOnly = (Get-ConfigLinuxOnly) -eq $true
    $validationError = Confirm-SetupTypeIsValid -SetupType $setupType
    $productVersion = "v$(Get-ProductVersion)"

    if ($validationError) {
        $linuxOnly = $null
        $productVersion = $null
    }

    return [pscustomobject]@{
        Name            = $setupType; 
        Version         = $productVersion; 
        ValidationError = $validationError; 
        LinuxOnly       = $linuxOnly
    }
}

Export-ModuleMember -Function Get-SetupInfo