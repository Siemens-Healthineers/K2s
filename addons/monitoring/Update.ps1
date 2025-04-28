# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$monitoringModule = "$PSScriptRoot\monitoring.module.psm1"

Import-Module $addonsModule, $monitoringModule

Update-IngressForAddon -Addon ([pscustomobject] @{Name = 'monitoring' })

$EnancedSecurityEnabled = Test-LinkerdServiceAvailability
if ($EnancedSecurityEnabled) {
    Write-Log "Updating monitoring addon to be part of service mesh"  
    $annotations1 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/skip-inbound-ports\":\"10250\"}}}}}'
    (Invoke-Kubectl -Params 'patch', 'deployment', 'kube-prometheus-stack-operator', '-n', 'monitoring', '-p', $annotations1).Output | Write-Log
    $annotations2 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/skip-outbound-ports\":\"9100\"}}}}}'
    (Invoke-Kubectl -Params 'patch', 'deployment', 'kube-prometheus-stack-plutono', '-n', 'monitoring', '-p', $annotations2).Output | Write-Log
    $annotations3 = '{\"spec\":{\"podMetadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\"}}}}'
    (Invoke-Kubectl -Params 'patch', 'prometheus', 'kube-prometheus-stack-prometheus', '-n', 'monitoring', '-p', $annotations3, '--type=merge').Output | Write-Log
    $annotations4 = '{\"spec\":{\"podMetadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\"}}}}'
    (Invoke-Kubectl -Params 'patch', 'alertmanager', 'kube-prometheus-stack-alertmanager', '-n', 'monitoring', '-p', $annotations4, '--type=merge').Output | Write-Log
    $annotations5 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\"}}}}}'
    (Invoke-Kubectl -Params 'patch', 'deployment', 'kube-prometheus-stack-kube-state-metrics', '-n', 'monitoring', '-p', $annotations5).Output | Write-Log
} else {
    Write-Log "Updating monitoring addon to not be part of service mesh"
    $annotations1 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config.linkerd.io/skip-inbound-ports\":null,\"config.linkerd.io/skip-outbound-ports\":null,\"linkerd.io/inject\":null}}}}}'
    (Invoke-Kubectl -Params 'patch', 'deployment', 'kube-prometheus-stack-operator', '-n', 'monitoring', '-p', $annotations1).Output | Write-Log
    (Invoke-Kubectl -Params 'patch', 'deployment', 'kube-prometheus-stack-plutono', '-n', 'monitoring', '-p', $annotations1).Output | Write-Log
    (Invoke-Kubectl -Params 'patch', 'deployment', 'kube-prometheus-stack-kube-state-metrics', '-n', 'monitoring', '-p', $annotations1).Output | Write-Log
    $annotations2 = '{\"spec\":{\"podMetadata\":{\"annotations\":{\"linkerd.io/inject\":null}}}}'
    (Invoke-Kubectl -Params 'patch', 'prometheus', 'kube-prometheus-stack-prometheus', '-n', 'monitoring', '-p', $annotations2, '--type=merge').Output | Write-Log
    (Invoke-Kubectl -Params 'patch', 'alertmanager', 'kube-prometheus-stack-alertmanager', '-n', 'monitoring', '-p', $annotations2, '--type=merge').Output | Write-Log
}
(Invoke-Kubectl -Params 'rollout', 'status', 'deployment', '-n', 'monitoring', '--timeout', '60s').Output | Write-Log
(Invoke-Kubectl -Params 'rollout', 'status', 'statefulset', '-n', 'monitoring', '--timeout', '60s').Output | Write-Log

Write-Log 'Updating monitoring addon finished.' -Console