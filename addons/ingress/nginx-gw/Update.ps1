# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"
$nginxGateWayModule = "$PSScriptRoot\nginx-gw.module.psm1"
Import-Module $addonsModule, $nginxGateWayModule

$addonName = Get-AddonNameFromFolderPath -BaseFolderPath $PSScriptRoot
Write-Log "Updating addon with name: $addonName"

$EnancedSecurityEnabled = Test-LinkerdServiceAvailability
if ($EnancedSecurityEnabled) {
	Write-Log "Updating nginx gateway fabric addon to be part of service mesh"
	$annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config.linkerd.io/skip-inbound-ports\":\"443,8443,9113\",\"config.linkerd.io/skip-outbound-ports\":\"443\",\"linkerd.io/inject\":\"enabled\"}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'nginx-gw-controller', '-n', 'nginx-gw', '-p', $annotations).Output | Write-Log
	
	$maxAttempts = 30
	$attempt = 0
	do {
		$attempt++
		$deployment = (Invoke-Kubectl -Params 'get', 'deployment', 'nginx-gw-controller', '-n', 'nginx-gw', '-o', 'json').Output | ConvertFrom-Json
		$hasAnnotation = $deployment.spec.template.metadata.annotations.'linkerd.io/inject' -eq 'enabled'
		if (-not $hasAnnotation) {
			Write-Log "Waiting for patch to be applied (attempt $attempt of $maxAttempts)..."
			Start-Sleep -Seconds 2
		}
	} while (-not $hasAnnotation -and $attempt -lt $maxAttempts)

	if (-not $hasAnnotation) {
		throw "Timeout waiting for patch to be applied"
	}
} else {
	Write-Log "Updating nginx gateway fabric addon to not be part of service mesh"
	$annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config.linkerd.io/skip-inbound-ports\":null,\"config.linkerd.io/skip-outbound-ports\":null,\"linkerd.io/inject\":null}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'nginx-gw-controller', '-n', 'nginx-gw', '-p', $annotations).Output | Write-Log

	$maxAttempts = 30
	$attempt = 0
	do {
		$attempt++
		$deployment = (Invoke-Kubectl -Params 'get', 'deployment', 'nginx-gw-controller', '-n', 'nginx-gw', '-o', 'json').Output | ConvertFrom-Json
		$hasNoAnnotation = $null -eq $deployment.spec.template.metadata.annotations.'linkerd.io/inject'
		if (-not $hasNoAnnotation) {
			Write-Log "Waiting for patch to be applied (attempt $attempt of $maxAttempts)..."
			Start-Sleep -Seconds 2
		}
	} while (-not $hasNoAnnotation -and $attempt -lt $maxAttempts)

	if (-not $hasNoAnnotation) {
		throw "Timeout waiting for patch to be applied"
	}
}
(Invoke-Kubectl -Params 'rollout', 'status', 'deployment', '-n', 'nginx-gw-controller', '--timeout', '60s').Output | Write-Log
Write-Log 'Updating nginx gateway fabric addon finished.' -Console
