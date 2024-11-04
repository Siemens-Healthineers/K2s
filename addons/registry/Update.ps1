# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$registryModule = "$PSScriptRoot\registry.module.psm1"
$imageRegistryModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.cluster.module\image\registry\registry.module.psm1"

Import-Module $addonsModule, $registryModule, $imageRegistryModule

$Addon = [pscustomobject] @{Name = 'registry' }

Remove-RegistryFromSetupJson -Name 'k2s.registry*' -IsRegex $true

if (Test-NginxIngressControllerAvailability) {
    $registryName = 'k2s.registry.local'

    Remove-IngressForTraefik -Addon $Addon
    Remove-NodePort

    Remove-InsecureRegistry -Name "k2s.registry.local*"
    Set-InsecureRegistry -Name $registryName -Https

    $props = Get-AddonProperties -Addon $Addon

    Write-Log "  Applying nginx ingress manifest for $($props.Name)..." -Console
    $kustomizationDir = Get-IngressNginxConfig -Directory $props.Directory

    Invoke-Kubectl -Params 'apply', '-k', $kustomizationDir | Out-Null
}
elseif (Test-TraefikIngressControllerAvailability) {
    $registryName = 'k2s.registry.local'

    Remove-IngressForNginx -Addon $Addon
    Remove-NodePort

    Remove-InsecureRegistry -Name "k2s.registry.local*"
    Set-InsecureRegistry -Name $registryName -Https

    Update-IngressForTraefik -Addon $Addon
}
else {
    $registryName = 'k2s.registry.local:30500'

    Remove-IngressForNginx -Addon $Addon
    Remove-IngressForTraefik -Addon $Addon

    Update-NodePort

    Remove-InsecureRegistry -Name "k2s.registry.local*"
    Set-InsecureRegistry -Name $registryName
}

Add-RegistryToSetupJson -Name $registryName