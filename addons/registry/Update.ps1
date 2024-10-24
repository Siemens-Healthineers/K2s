# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$registryModule = "$PSScriptRoot\registry.module.psm1"

Import-Module $addonsModule, $registryModule

$Addon = [pscustomobject] @{Name = 'registry' }
$registryName = 'k2s.registry.local'

if (Test-NginxIngressControllerAvailability) {
    Remove-IngressForTraefik -Addon $Addon
    Remove-NodePort

    $props = Get-AddonProperties -Addon $Addon

    if (Test-KeyCloakServiceAvailability) {
        Write-Log "  Applying secure nginx ingress manifest for $($props.Name)..." -Console
        $kustomizationDir = Get-IngressNginxSecureConfig -Directory $props.Directory
    }
    else {
        Write-Log "  Applying nginx ingress manifest for $($props.Name)..." -Console
        $kustomizationDir = Get-IngressNginxConfig -Directory $props.Directory
        Set-InsecureRegistry
    }
    Invoke-Kubectl -Params 'apply', '-k', $kustomizationDir | Out-Null
}
elseif (Test-TraefikIngressControllerAvailability) {
    Remove-IngressForNginx -Addon $Addon
    Remove-NodePort

    Update-IngressForTraefik -Addon $Addon
}
else {
    Remove-IngressForNginx -Addon $Addon
    Remove-IngressForTraefik -Addon $Addon

    Update-NodePort
    $registryName = "$($registryName):$Nodeport"
}

Write-RegistryUsageForUser -registryName $registryName
Add-RegistryToSetupJson -Name $registryName