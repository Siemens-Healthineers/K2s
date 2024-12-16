# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
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

    Remove-Registry -Name "k2s.registry.local*"
    Set-Registry -Name $registryName -Https -LocalRegistry

    $props = Get-AddonProperties -Addon $Addon

    Write-Log "  Applying nginx ingress manifest for $($props.Name)..." -Console
    $kustomizationDir = Get-IngressNginxConfig -Directory $props.Directory

    Invoke-Kubectl -Params 'apply', '-k', $kustomizationDir | Out-Null
}
elseif (Test-TraefikIngressControllerAvailability) {
    $registryName = 'k2s.registry.local'

    Remove-IngressForNginx -Addon $Addon
    Remove-NodePort

    Remove-Registry -Name "k2s.registry.local*"
    Set-Registry -Name $registryName -Https -LocalRegistry

    Update-IngressForTraefik -Addon $Addon
}
else {
    $registryName = 'k2s.registry.local:30500'

    Remove-IngressForNginx -Addon $Addon
    Remove-IngressForTraefik -Addon $Addon

    Update-NodePort

    Remove-Registry -Name "k2s.registry.local*"
    Set-Registry -Name $registryName -LocalRegistry
}

Add-RegistryToSetupJson -Name $registryName