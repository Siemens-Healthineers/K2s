# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Import-Module "$PSScriptRoot/security.module.psm1"

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

return $certManagerProp, $caRootCertificateProp