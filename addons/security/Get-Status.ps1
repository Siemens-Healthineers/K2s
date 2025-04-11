# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$securityModule = "$PSScriptRoot\security.module.psm1"

Import-Module $addonsModule, $securityModule

$certManagerAvailable = Wait-ForCertManagerAvailable
$certManagerProp = @{Name = 'IsCertManagerAvailable'; Value = $certManagerAvailable; Okay = $certManagerAvailable }
if ($certManagerProp.Value -eq $true) {
    $certManagerProp.Message = 'The cert-manager API is ready'
}
else {
    $certManagerProp.Message = 'The cert-manager API is not ready. Please use cmctl.exe for further diagnostics.'
} 

$caRootCertificateAvailable = Wait-ForCARootCertificate
$caRootCertificateProp = @{Name = 'IsCaRootCertificateAvailable'; Value = $caRootCertificateAvailable; Okay = $caRootCertificateAvailable }
if ($caRootCertificateProp.Value -eq $true) {
    $caRootCertificateProp.Message = 'The CA root certificate is available'
}
else {
    $caRootCertificateProp.Message = "The CA root certificate is not available ('ca-issuer-root-secret' not created)."
} 

$EnancedSecurityEnabled = Test-LinkerdServiceAvailability
$securityProp = @{Name = 'Type of security'; Value = $EnancedSecurityEnabled; Okay = $certManagerAvailable }
$linkerdProp = @{Name = 'Type of security'; Value = $EnancedSecurityEnabled; Okay = $EnancedSecurityEnabled  }
if ($certManagerAvailable) {
    if ($EnancedSecurityEnabled) {
        $securityProp.Message = 'Type of security: enhanced'
        $linkerdProp.Message = 'The linkerd API is ready'
    } else {
        $securityProp.Message = 'Type of security: basic' 
        $linkerdProp.Message = 'The linkerd API is not available because of basic security'
    }
} else {
    $securityProp.Message = 'Type of security: none'
    $linkerdProp.Message = 'The linkerd API is not available'
}

$trustManagerAvailable = Test-TrustManagerServiceAvailability
$trustManagerProp = @{Name = 'IsTrustManagerAvailable'; Value = $trustManagerAvailable; Okay = $trustManagerAvailable }
if ($trustManagerProp.Value -eq $true) {
    $trustManagerProp.Message = 'The trust-manager API is ready'
}
else {
    $trustManagerProp.Message = 'The trust-manager API is not available because of basic security'
}

$keycloakAvailable = Test-KeyCloakServiceAvailability
$keycloakProp = @{Name = 'IsKeycloakAvailable'; Value = $keycloakAvailable; Okay = $keycloakAvailable }
if ($keycloakProp.Value -eq $true) {
    $keycloakProp.Message = 'The keycloak API is ready'
}
else {
    $keycloakProp.Message = 'The keycloak API is not ready'
}

return $securityProp, $certManagerProp, $caRootCertificateProp, $keycloakProp, $trustManagerProp, $linkerdProp