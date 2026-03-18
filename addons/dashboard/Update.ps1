# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
	[parameter(Mandatory = $false, HelpMessage = 'Preferred ingress integration to apply (auto/nginx/traefik/nginx-gw/none)')]
	[ValidateSet('auto', 'nginx', 'traefik', 'nginx-gw', 'none')]
	[string] $PreferredIngress = 'auto'
)

$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$dashboardModule = "$PSScriptRoot\dashboard.module.psm1"

Import-Module $addonsModule, $dashboardModule

$addonObj = [pscustomobject] @{ Name = 'dashboard' }

if ($PreferredIngress -eq 'auto') {
	Update-IngressForAddon -Addon $addonObj
}
elseif ($PreferredIngress -eq 'none') {
	Remove-IngressForTraefik -Addon $addonObj
	Remove-IngressForNginx -Addon $addonObj
	Remove-IngressForNginxGateway -Addon $addonObj
}
elseif ($PreferredIngress -eq 'nginx') {
	Remove-IngressForTraefik -Addon $addonObj
	Remove-IngressForNginxGateway -Addon $addonObj
	Update-IngressForNginx -Addon $addonObj
}
elseif ($PreferredIngress -eq 'traefik') {
	Remove-IngressForNginx -Addon $addonObj
	Remove-IngressForNginxGateway -Addon $addonObj
	Update-IngressForTraefik -Addon $addonObj
}
elseif ($PreferredIngress -eq 'nginx-gw') {
	Remove-IngressForTraefik -Addon $addonObj
	Remove-IngressForNginx -Addon $addonObj
	Update-IngressForNginxGateway -Addon $addonObj
}

# Service mesh (Linkerd) integration for the single Headlamp deployment
$linkerdEnabled = Test-LinkerdServiceAvailability
$patchApplied = $false
if ($linkerdEnabled) {
	Write-Log '[Dashboard] Updating Headlamp addon to be part of service mesh' -Console
	$annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\"}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'headlamp', '-n', 'dashboard', '-p', $annotations).Output | Write-Log

	$maxAttempts = 30
	$attempt = 0
	$hasAnnotation = $false
	do {
		$attempt++
		$headlampDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'headlamp', '-n', 'dashboard', '-o', 'json').Output | ConvertFrom-Json
		# Guard against null annotations object on fresh deployment
		$linkerdAnnotation = $null
		if ($null -ne $headlampDeployment.spec.template.metadata.annotations) {
			$linkerdAnnotation = $headlampDeployment.spec.template.metadata.annotations.'linkerd.io/inject'
		}
		$hasAnnotation = ($linkerdAnnotation -eq 'enabled')
		if (-not $hasAnnotation) {
			Write-Log "[Dashboard] Waiting for Linkerd patch to be applied (attempt $attempt of $maxAttempts)..."
			Start-Sleep -Seconds 2
		}
	} while (-not $hasAnnotation -and $attempt -lt $maxAttempts)

	if (-not $hasAnnotation) {
		throw '[Dashboard] Timeout waiting for Linkerd patch to be applied to headlamp deployment'
	}
	$patchApplied = $true
}
else {
	# Check whether the annotation is already absent before patching to avoid an
	# unnecessary pod restart on every dashboard enable when Linkerd was never installed.
	$currentDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'headlamp', '-n', 'dashboard', '-o', 'json').Output | ConvertFrom-Json
	$currentAnnotation = $null
	if ($null -ne $currentDeployment.spec.template.metadata.annotations) {
		$currentAnnotation = $currentDeployment.spec.template.metadata.annotations.'linkerd.io/inject'
	}

	if ($null -ne $currentAnnotation) {
		Write-Log '[Dashboard] Removing Headlamp from service mesh (Linkerd not running)' -Console
		$annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":null}}}}}'
		(Invoke-Kubectl -Params 'patch', 'deployment', 'headlamp', '-n', 'dashboard', '-p', $annotations).Output | Write-Log

		$maxAttempts = 30
		$attempt = 0
		$hasNoAnnotation = $false
		do {
			$attempt++
			$headlampDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'headlamp', '-n', 'dashboard', '-o', 'json').Output | ConvertFrom-Json
			$linkerdAnnotation = $null
			if ($null -ne $headlampDeployment.spec.template.metadata.annotations) {
				$linkerdAnnotation = $headlampDeployment.spec.template.metadata.annotations.'linkerd.io/inject'
			}
			$hasNoAnnotation = ($null -eq $linkerdAnnotation)
			if (-not $hasNoAnnotation) {
				Write-Log "[Dashboard] Waiting for Linkerd patch removal (attempt $attempt of $maxAttempts)..."
				Start-Sleep -Seconds 2
			}
		} while (-not $hasNoAnnotation -and $attempt -lt $maxAttempts)

		if (-not $hasNoAnnotation) {
			throw '[Dashboard] Timeout waiting for Linkerd patch removal from headlamp deployment'
		}
		$patchApplied = $true
	}
	else {
		Write-Log '[Dashboard] Headlamp is already not part of service mesh, no patch required' -Console
	}
}

if ($patchApplied) {
	(Invoke-Kubectl -Params 'rollout', 'status', 'deployment', 'headlamp', '-n', 'dashboard', '--timeout', '60s').Output | Write-Log
}

Write-Log '[Dashboard] Updating dashboard addon finished.' -Console
