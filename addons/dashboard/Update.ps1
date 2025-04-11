# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$dashboardModule = "$PSScriptRoot\dashboard.module.psm1"

Import-Module $addonsModule, $dashboardModule

Update-IngressForAddon -Addon ([pscustomobject] @{Name = 'dashboard' })

$EnancedSecurityEnabled = Test-LinkerdServiceAvailability
if ($EnancedSecurityEnabled) {
    Write-Log "Updating dashboard addon to be part of service mesh"  
    $annotations1 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/skip-inbound-ports\":\"8443\"}}}}}'
    (Invoke-Kubectl -Params 'patch', 'deployment', 'kubernetes-dashboard', '-n', 'dashboard', '-p', $annotations1).Output | Write-Log
    $annotations2 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/skip-inbound-ports\":\"8000\"}}}}}'
    (Invoke-Kubectl -Params 'patch', 'deployment', 'dashboard-metrics-scraper', '-n', 'dashboard', '-p', $annotations2).Output | Write-Log
} else {
    Write-Log "Updating nginx ingress addon to not be part of service mesh"
    $annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config.linkerd.io/skip-inbound-ports\":null,\"linkerd.io/inject\":null}}}}}'
    (Invoke-Kubectl -Params 'patch', 'deployment', 'kubernetes-dashboard', '-n', 'dashboard', '-p', $annotations).Output | Write-Log
    (Invoke-Kubectl -Params 'patch', 'deployment', 'dashboard-metrics-scraper', '-n', 'dashboard', '-p', $annotations).Output | Write-Log
}
(Invoke-Kubectl -Params 'rollout', 'status', 'deployment', '-n', 'dashboard', '--timeout', '60s').Output | Write-Log

Write-Log 'Updating dashboard addon finished.' -Console