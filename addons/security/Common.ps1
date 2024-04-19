# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Contains common methods for installing and uninstalling security
#>

<#
.DESCRIPTION
Gets the location of manifests to deploy security
#>
function Get-CertManagerConfig {
    return "$PSScriptRoot\manifests\cert-manager.yaml"
}

<#
.DESCRIPTION
Gets the location of nginx ingress yaml for dashboard
#>
function Get-CAIssuerConfig {
    return "$PSScriptRoot\manifests\ca-issuer.yaml"
}

<#
.DESCRIPTION
Writes the usage notes for security for the user.
#>
function Write-UsageForUser {
    @'
USAGE NOTES

This addon is documented in <installation folder>\addons\security\README.md
'@ -split "`r`n" | ForEach-Object { Write-Host $_ }
}

<#
.DESCRIPTION
Waits for the cert-manager API to be available.
#>
function Wait-ForCertManagerAvailable {
    $out = &$global:BinPath\exe\cmctl.exe check api --wait=3m
    if ($out -match 'The cert-manager API is ready') {
        return $true
    }
    else {
        return $false
    }
}


<#
.DESCRIPTION
Waits for the kubernetes secret 'ca-issuer-root-secret' in the namespace 'cert-manager' to be created.
#>
function Wait-ForCARootCertificate(
    [int]$SleepDurationInSeconds = 10,
    [int]$NumberOfRetries = 10) {
    $found = $false
    for (($i = 1); $i -le $NumberOfRetries; $i++) {
        $out = &$global:KubectlExe -n cert-manager get secrets ca-issuer-root-secret -o=jsonpath="{.metadata.name}" --ignore-not-found
        if ($out -match 'ca-issuer-root-secret') {
            Write-Log "'ca-issuer-root-secret' created and ready for use."
            $found = $true
            break;
        }
        Write-Log "Retry {$i}: 'ca-issuer-root-secret' not yet created. Will retry after $SleepDurationInSeconds Seconds" -Console
        Start-Sleep -Seconds $SleepDurationInSeconds
    }
    return $found


    $out = &$global:BinPath\exe\cmctl.exe check api --wait=3m
    if ($out -match 'The cert-manager API is ready') {
        return $true
    }
    else {
        return $false
    }
}
