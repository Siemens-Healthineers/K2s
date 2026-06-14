# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$securityModule = "$PSScriptRoot\security.module.psm1"
$dashboardModule = "$PSScriptRoot\..\dashboard\dashboard.module.psm1"

Import-Module $addonsModule, $securityModule

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

if (Test-Path $dashboardModule) {
    Import-Module $dashboardModule -Force
    if (Get-Command Sync-HeadlampPlugins -ErrorAction SilentlyContinue) {
        Write-Log '[Dashboard][Plugin] Syncing Headlamp plugins after security update' -Console
        Sync-HeadlampPlugins
    }
}
