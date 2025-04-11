# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$metricsModule = "$PSScriptRoot\metrics.module.psm1"
Import-Module $addonsModule, $metricsModule

$EnancedSecurityEnabled = Test-LinkerdServiceAvailability
if ($EnancedSecurityEnabled) {
    Write-Log "Updating metrics addon to be part of service mesh"  
    $annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/skip-inbound-ports\":\"4443\"}}}}}'
    (Invoke-Kubectl -Params 'patch', 'deployment', 'metrics-server', '-n', 'metrics', '-p', $annotations).Output | Write-Log
} else {
    Write-Log "Updating metrics addon to not be part of service mesh"
    $annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config.linkerd.io/skip-inbound-ports\":null,\"linkerd.io/inject\":null}}}}}'
    (Invoke-Kubectl -Params 'patch', 'deployment', 'metrics-server', '-n', 'metrics', '-p', $annotations).Output | Write-Log
}
(Invoke-Kubectl -Params 'rollout', 'status', 'deployment', '-n', 'metrics', '--timeout', '60s').Output | Write-Log

Write-Log 'Updating metrics addon finished.' -Console