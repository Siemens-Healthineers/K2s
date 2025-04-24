# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$loggingModule = "$PSScriptRoot\logging.module.psm1"

Import-Module $addonsModule, $loggingModule

Update-IngressForAddon -Addon ([pscustomobject] @{Name = 'logging' })

$EnancedSecurityEnabled = Test-LinkerdServiceAvailability
if ($EnancedSecurityEnabled) {
    Write-Log "Updating logging addon to be part of service mesh"  
    $annotations1 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/skip-inbound-ports\":\"9200\"}}}}}'
    (Invoke-Kubectl -Params 'patch', 'statefulset', 'opensearch-cluster-master', '-n', 'logging', '-p', $annotations1).Output | Write-Log
    $annotations2 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\"}}}}}'
    (Invoke-Kubectl -Params 'patch', 'deployment', 'opensearch-dashboards', '-n', 'logging', '-p', $annotations2).Output | Write-Log
    $annotations3 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/skip-outbound-ports\":\"9200\"}}}}}'
    (Invoke-Kubectl -Params 'patch', 'daemonset', 'fluent-bit', '-n', 'logging', '-p', $annotations3).Output | Write-Log
} else {
    Write-Log "Updating logging addon to not be part of service mesh"
    $annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config.linkerd.io/skip-inbound-ports\":null,\"config.linkerd.io/skip-outbound-ports\":null,\"linkerd.io/inject\":null}}}}}'
    (Invoke-Kubectl -Params 'patch', 'statefulset', 'opensearch-cluster-master', '-n', 'logging', '-p', $annotations).Output | Write-Log
    (Invoke-Kubectl -Params 'patch', 'deployment', 'opensearch-dashboards', '-n', 'logging', '-p', $annotations).Output | Write-Log
    (Invoke-Kubectl -Params 'patch', 'daemonset', 'fluent-bit', '-n', 'logging', '-p', $annotations).Output | Write-Log
}
(Invoke-Kubectl -Params 'rollout', 'status', 'deployment', '-n', 'logging', '--timeout', '60s').Output | Write-Log
(Invoke-Kubectl -Params 'rollout', 'status', 'statefulset', '-n', 'logging', '--timeout', '60s').Output | Write-Log
(Invoke-Kubectl -Params 'rollout', 'status', 'daemonset', '-n', 'logging', '--timeout', '60s').Output | Write-Log

Write-Log 'Updating logging addon finished.' -Console