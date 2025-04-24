# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
Import-Module $addonsModule

$EnancedSecurityEnabled = Test-LinkerdServiceAvailability
if ($EnancedSecurityEnabled) {
    Write-Log "Updating autoscaling addon to be part of service mesh"  
    $annotations1 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/skip-inbound-ports\":\"8081\"}}}}}'
    (Invoke-Kubectl -Params 'patch', 'deployment', 'keda-admission', '-n', 'autoscaling', '-p', $annotations1).Output | Write-Log
    $annotations2 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/skip-inbound-ports\":\"6443\"}}}}}'
    (Invoke-Kubectl -Params 'patch', 'deployment', 'keda-metrics-apiserver', '-n', 'autoscaling', '-p', $annotations2).Output | Write-Log
    $annotations3 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/skip-inbound-ports\":\"8081\"}}}}}'
    (Invoke-Kubectl -Params 'patch', 'deployment', 'keda-operator', '-n', 'autoscaling', '-p', $annotations3).Output | Write-Log
} else {
    Write-Log "Updating autoscaling addon to not be part of service mesh"
    $annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config.linkerd.io/skip-inbound-ports\":null,\"linkerd.io/inject\":null}}}}}'
    (Invoke-Kubectl -Params 'patch', 'deployment', 'keda-admission', '-n', 'autoscaling', '-p', $annotations).Output | Write-Log
    (Invoke-Kubectl -Params 'patch', 'deployment', 'keda-metrics-apiserver', '-n', 'autoscaling', '-p', $annotations).Output | Write-Log
    (Invoke-Kubectl -Params 'patch', 'deployment', 'keda-operator', '-n', 'autoscaling', '-p', $annotations).Output | Write-Log
}
(Invoke-Kubectl -Params 'rollout', 'status', 'deployment', '-n', 'autoscaling', '--timeout', '60s').Output | Write-Log

Write-Log 'Updating autoscaling addon finished.' -Console