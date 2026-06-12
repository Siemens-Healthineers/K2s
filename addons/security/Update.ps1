# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$addonsModule    = "$PSScriptRoot\..\addons.module.psm1"
$securityModule  = "$PSScriptRoot\security.module.psm1"
$dashboardModule = "$PSScriptRoot\..\dashboard\dashboard.module.psm1"

Import-Module $addonsModule, $securityModule

# Optional Dashboard integration: import the Dashboard module only if it is packaged.
# Allows security to work in offline packages that do not include the dashboard addon.
if (Test-Path $dashboardModule) {
    Import-Module $dashboardModule -DisableNameChecking
}

Remove-IngressForSecurity
if (Test-NginxIngressControllerAvailability) {
    Enable-IngressForSecurity -Ingress 'nginx'
}
elseif (Test-TraefikIngressControllerAvailability) {
    Enable-IngressForSecurity -Ingress 'traefik'
}
elseif (Test-NginxGatewayAvailability) {
    Enable-IngressForSecurity -Ingress 'nginx-gw'
}

Write-Log 'Updating security addon finished.' -Console

Write-Log '[Dashboard][Plugin] Syncing Headlamp plugins after security update' -Console
if (Get-Command Sync-HeadlampPlugins -ErrorAction SilentlyContinue) {
    Sync-HeadlampPlugins
}
