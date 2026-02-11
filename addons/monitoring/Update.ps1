# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$monitoringModule = "$PSScriptRoot\monitoring.module.psm1"

Import-Module $addonsModule, $monitoringModule

# Deploy Windows Exporter as HostProcess container (shared resource, idempotent)
Write-Log 'Deploying Windows Exporter (shared resource for metrics collection)' -Console
$windowsExporterManifest = Get-WindowsExporterManifestDir
(Invoke-Kubectl -Params 'apply', '-k', $windowsExporterManifest).Output | Write-Log

Update-IngressForAddon -Addon ([pscustomobject] @{Name = 'monitoring' })

$EnancedSecurityEnabled = Test-LinkerdServiceAvailability
if ($EnancedSecurityEnabled) {
	Write-Log "Updating monitoring addon to be part of service mesh"  
	$annotations1 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/skip-inbound-ports\":\"10250\"}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'kube-prometheus-stack-operator', '-n', 'monitoring', '-p', $annotations1).Output | Write-Log
	$annotations2 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/skip-outbound-ports\":\"9100\"}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'kube-prometheus-stack-grafana', '-n', 'monitoring', '-p', $annotations2).Output | Write-Log
	$annotations3 = '{\"spec\":{\"podMetadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\"}}}}'
	(Invoke-Kubectl -Params 'patch', 'prometheus', 'kube-prometheus-stack-prometheus', '-n', 'monitoring', '-p', $annotations3, '--type=merge').Output | Write-Log
	$annotations4 = '{\"spec\":{\"podMetadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\"}}}}'
	(Invoke-Kubectl -Params 'patch', 'alertmanager', 'kube-prometheus-stack-alertmanager', '-n', 'monitoring', '-p', $annotations4, '--type=merge').Output | Write-Log
	$annotations5 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\"}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'kube-prometheus-stack-kube-state-metrics', '-n', 'monitoring', '-p', $annotations5).Output | Write-Log

	# Patch Windows Exporter DaemonSet for service mesh
	Write-Log "Updating Windows Exporter to be part of service mesh"
	$annotations6 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\"}}}}}'
	(Invoke-Kubectl -Params 'patch', 'daemonset', 'windows-exporter', '-n', 'kube-system', '-p', $annotations6, '--ignore-not-found').Output | Write-Log

	$maxAttempts = 30
	$attempt = 0
	do {
		$attempt++
		$operatorDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'kube-prometheus-stack-operator', '-n', 'monitoring', '-o', 'json').Output | ConvertFrom-Json
		$grafanaDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'kube-prometheus-stack-grafana', '-n', 'monitoring', '-o', 'json').Output | ConvertFrom-Json
		$metricsDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'kube-prometheus-stack-kube-state-metrics', '-n', 'monitoring', '-o', 'json').Output | ConvertFrom-Json
		$prometheus = (Invoke-Kubectl -Params 'get', 'prometheus', 'kube-prometheus-stack-prometheus', '-n', 'monitoring', '-o', 'json').Output | ConvertFrom-Json
		$alertmanager = (Invoke-Kubectl -Params 'get', 'alertmanager', 'kube-prometheus-stack-alertmanager', '-n', 'monitoring', '-o', 'json').Output | ConvertFrom-Json

		$hasAnnotations = ($operatorDeployment.spec.template.metadata.annotations.'linkerd.io/inject' -eq 'enabled') -and
				($grafanaDeployment.spec.template.metadata.annotations.'linkerd.io/inject' -eq 'enabled') -and
				($metricsDeployment.spec.template.metadata.annotations.'linkerd.io/inject' -eq 'enabled') -and
				($prometheus.spec.podMetadata.annotations.'linkerd.io/inject' -eq 'enabled') -and
				($alertmanager.spec.podMetadata.annotations.'linkerd.io/inject' -eq 'enabled')
		if (-not $hasAnnotations) {
			Write-Log "Waiting for patches to be applied (attempt $attempt of $maxAttempts)..."
			Start-Sleep -Seconds 2
		}
	} while (-not $hasAnnotations -and $attempt -lt $maxAttempts)

	if (-not $hasAnnotations) {
		throw "Timeout waiting for patches to be applied"
	}
} else {
	Write-Log "Updating monitoring addon to not be part of service mesh"
	$annotations1 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config.linkerd.io/skip-inbound-ports\":null,\"config.linkerd.io/skip-outbound-ports\":null,\"linkerd.io/inject\":null}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'kube-prometheus-stack-operator', '-n', 'monitoring', '-p', $annotations1).Output | Write-Log
	(Invoke-Kubectl -Params 'patch', 'deployment', 'kube-prometheus-stack-grafana', '-n', 'monitoring', '-p', $annotations1).Output | Write-Log
	(Invoke-Kubectl -Params 'patch', 'deployment', 'kube-prometheus-stack-kube-state-metrics', '-n', 'monitoring', '-p', $annotations1).Output | Write-Log
	$annotations2 = '{\"spec\":{\"podMetadata\":{\"annotations\":{\"linkerd.io/inject\":null}}}}'
	(Invoke-Kubectl -Params 'patch', 'prometheus', 'kube-prometheus-stack-prometheus', '-n', 'monitoring', '-p', $annotations2, '--type=merge').Output | Write-Log
	(Invoke-Kubectl -Params 'patch', 'alertmanager', 'kube-prometheus-stack-alertmanager', '-n', 'monitoring', '-p', $annotations2, '--type=merge').Output | Write-Log

	# Remove Linkerd injection from Windows Exporter
	Write-Log "Updating Windows Exporter to not be part of service mesh"
	$annotations3 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":null}}}}}'
	(Invoke-Kubectl -Params 'patch', 'daemonset', 'windows-exporter', '-n', 'kube-system', '-p', $annotations3, '--ignore-not-found').Output | Write-Log

	$maxAttempts = 30
	$attempt = 0
	do {
		$attempt++
		$operatorDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'kube-prometheus-stack-operator', '-n', 'monitoring', '-o', 'json').Output | ConvertFrom-Json
		$grafanaDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'kube-prometheus-stack-grafana', '-n', 'monitoring', '-o', 'json').Output | ConvertFrom-Json
		$metricsDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'kube-prometheus-stack-kube-state-metrics', '-n', 'monitoring', '-o', 'json').Output | ConvertFrom-Json
		$prometheus = (Invoke-Kubectl -Params 'get', 'prometheus', 'kube-prometheus-stack-prometheus', '-n', 'monitoring', '-o', 'json').Output | ConvertFrom-Json
		$alertmanager = (Invoke-Kubectl -Params 'get', 'alertmanager', 'kube-prometheus-stack-alertmanager', '-n', 'monitoring', '-o', 'json').Output | ConvertFrom-Json

		$hasNoAnnotations = ($null -eq $operatorDeployment.spec.template.metadata.annotations.'linkerd.io/inject') -and
				($null -eq $grafanaDeployment.spec.template.metadata.annotations.'linkerd.io/inject') -and
				($null -eq $metricsDeployment.spec.template.metadata.annotations.'linkerd.io/inject') -and
				($null -eq $prometheus.spec.podMetadata.annotations.'linkerd.io/inject') -and
				($null -eq $alertmanager.spec.podMetadata.annotations.'linkerd.io/inject')
		if (-not $hasNoAnnotations) {
			Write-Log "Waiting for patches to be applied (attempt $attempt of $maxAttempts)..."
			Start-Sleep -Seconds 2
		}
	} while (-not $hasNoAnnotations -and $attempt -lt $maxAttempts)

	if (-not $hasNoAnnotations) {
		throw "Timeout waiting for patches to be applied"
	}
}
(Invoke-Kubectl -Params 'rollout', 'status', 'deployment', '-n', 'monitoring', '--timeout', '60s').Output | Write-Log
(Invoke-Kubectl -Params 'rollout', 'status', 'statefulset', '-n', 'monitoring', '--timeout', '60s').Output | Write-Log

Write-Log 'Updating monitoring addon finished.' -Console