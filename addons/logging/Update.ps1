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
	Write-Log "Updating metrics addon to not be part of service mesh"
	$annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config.linkerd.io/skip-inbound-ports\":null,\"linkerd.io/inject\":null}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'metrics-server', '-n', 'metrics', '-p', $annotations).Output | Write-Log

	$maxAttempts = 30
	$attempt = 0
	do {
		$attempt++
		$deployment = (Invoke-Kubectl -Params 'get', 'deployment', 'metrics-server', '-n', 'metrics', '-o', 'json').Output | ConvertFrom-Json
		$hasNoAnnotation = $null -eq $deployment.spec.template.metadata.annotations.'linkerd.io/inject'
		if (-not $hasNoAnnotation) {
			Write-Log "Waiting for patch to be applied (attempt $attempt of $maxAttempts)..."
			Start-Sleep -Seconds 2
		}
	} while (-not $hasNoAnnotation -and $attempt -lt $maxAttempts)

	if (-not $hasNoAnnotation) {
		throw "Timeout waiting for patch to be applied"
	}
} else {
	Write-Log "Updating logging addon to not be part of service mesh"
	$annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config.linkerd.io/skip-inbound-ports\":null,\"config.linkerd.io/skip-outbound-ports\":null,\"linkerd.io/inject\":null}}}}}'
	(Invoke-Kubectl -Params 'patch', 'statefulset', 'opensearch-cluster-master', '-n', 'logging', '-p', $annotations).Output | Write-Log
	(Invoke-Kubectl -Params 'patch', 'deployment', 'opensearch-dashboards', '-n', 'logging', '-p', $annotations).Output | Write-Log
	(Invoke-Kubectl -Params 'patch', 'daemonset', 'fluent-bit', '-n', 'logging', '-p', $annotations).Output | Write-Log

	$maxAttempts = 30
	$attempt = 0
	do {
		$attempt++
		$statefulset = (Invoke-Kubectl -Params 'get', 'statefulset', 'opensearch-cluster-master', '-n', 'logging', '-o', 'json').Output | ConvertFrom-Json
		$deployment = (Invoke-Kubectl -Params 'get', 'deployment', 'opensearch-dashboards', '-n', 'logging', '-o', 'json').Output | ConvertFrom-Json
		$daemonset = (Invoke-Kubectl -Params 'get', 'daemonset', 'fluent-bit', '-n', 'logging', '-o', 'json').Output | ConvertFrom-Json
		
		$hasNoAnnotations = ($null -eq $statefulset.spec.template.metadata.annotations.'linkerd.io/inject') -and
						   ($null -eq $deployment.spec.template.metadata.annotations.'linkerd.io/inject') -and
						   ($null -eq $daemonset.spec.template.metadata.annotations.'linkerd.io/inject')
		if (-not $hasNoAnnotations) {
			Write-Log "Waiting for patches to be applied (attempt $attempt of $maxAttempts)..."
			Start-Sleep -Seconds 2
		}
	} while (-not $hasNoAnnotations -and $attempt -lt $maxAttempts)

	if (-not $hasNoAnnotations) {
		throw "Timeout waiting for patches to be applied"
	}
}
(Invoke-Kubectl -Params 'rollout', 'status', 'deployment', '-n', 'logging', '--timeout', '60s').Output | Write-Log
(Invoke-Kubectl -Params 'rollout', 'status', 'statefulset', '-n', 'logging', '--timeout', '60s').Output | Write-Log
(Invoke-Kubectl -Params 'rollout', 'status', 'daemonset', '-n', 'logging', '--timeout', '60s').Output | Write-Log

Write-Log 'Updating logging addon finished.' -Console