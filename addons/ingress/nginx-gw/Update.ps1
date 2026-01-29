# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"
$nginxGateWayModule = "$PSScriptRoot\nginx-gw.module.psm1"
Import-Module $addonsModule, $nginxGateWayModule

# Local helper function for patching deployment annotations and verifying
function Update-LinkerdAnnotation {
	param (
		[string]$AnnotationsPatch,
		[string]$ExpectedValue,
		[int]$MaxAttempts = 30
	)
	
	# Apply patch
	(Invoke-Kubectl -Params 'patch', 'deployment', 'nginx-gw-controller', '-n', 'nginx-gw', '-p', $AnnotationsPatch).Output | Write-Log
	
	# Verify patch was applied
	$attempt = 0
	do {
		$attempt++
		$deployment = (Invoke-Kubectl -Params 'get', 'deployment', 'nginx-gw-controller', '-n', 'nginx-gw', '-o', 'json').Output | ConvertFrom-Json
		$currentValue = $deployment.spec.template.metadata.annotations.'linkerd.io/inject'
		$isPatched = $currentValue -eq $ExpectedValue
		
		if (-not $isPatched) {
			Write-Log "Waiting for patch to be applied (attempt $attempt of $MaxAttempts)..."
			Start-Sleep -Seconds 2
		}
	} while (-not $isPatched -and $attempt -lt $MaxAttempts)

	if (-not $isPatched) {
		throw "Timeout waiting for linkerd annotation patch to be applied"
	}
}

$addonName = Get-AddonNameFromFolderPath -BaseFolderPath $PSScriptRoot
Write-Log "Updating addon with name: $addonName"

$EnancedSecurityEnabled = Test-LinkerdServiceAvailability
if ($EnancedSecurityEnabled) {
	Write-Log "Updating nginx gateway fabric addon to be part of service mesh"
	$annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config.linkerd.io/skip-inbound-ports\":\"443,8443,9113\",\"config.linkerd.io/skip-outbound-ports\":\"443\",\"linkerd.io/inject\":\"enabled\"}}}}}'
	Update-LinkerdAnnotation -AnnotationsPatch $annotations -ExpectedValue 'enabled'
} else {
	Write-Log "Updating nginx gateway fabric addon to not be part of service mesh"
	$annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config.linkerd.io/skip-inbound-ports\":null,\"config.linkerd.io/skip-outbound-ports\":null,\"linkerd.io/inject\":null}}}}}'
	Update-LinkerdAnnotation -AnnotationsPatch $annotations -ExpectedValue $null
}
(Invoke-Kubectl -Params 'rollout', 'status', 'deployment', '-n', 'nginx-gw-controller', '--timeout', '60s').Output | Write-Log
Write-Log 'Updating nginx gateway fabric addon finished.' -Console
