# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$dicomModule = "$PSScriptRoot\dicom.module.psm1"
Import-Module $addonsModule, $dicomModule

$addonName = Get-AddonNameFromFolderPath -BaseFolderPath $PSScriptRoot

Update-IngressForAddon -Addon ([pscustomobject] @{Name = $addonName })

$bStorageAddonEnabled = Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'storage' })
$dicomAttributes = Get-AddonConfig -Name $addonName
Write-Log "Storage usage: $($dicomAttributes.StorageUsage) and storage addon enabled: $bStorageAddonEnabled" 
if ($dicomAttributes.StorageUsage -ne 'storage' -and $bStorageAddonEnabled) {
	Write-Log ' ' -Console
	Write-Log '!!!! DICOM addon is enabled. Please disable and enable DICOM addon again for a change in storage !!!!' -Console
	Write-Log ' ' -Console
}

$EnancedSecurityEnabled = Test-LinkerdServiceAvailability
if ($EnancedSecurityEnabled) {
	Write-Log "Updating dicom addon to be part of service mesh"  
	$annotations1 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/opaque-ports\":\"5432\"}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'dicom', '-n', 'dicom', '-p', $annotations1).Output | Write-Log
	$annotations2 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/opaque-ports\":\"5432\"}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'postgres', '-n', 'dicom', '-p', $annotations2).Output | Write-Log

	$maxAttempts = 30
	$attempt = 0
	do {
		$attempt++
		$dicomDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'dicom', '-n', 'dicom', '-o', 'json').Output | ConvertFrom-Json
		$postgresDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'postgres', '-n', 'dicom', '-o', 'json').Output | ConvertFrom-Json
		$hasAnnotations = ($dicomDeployment.spec.template.metadata.annotations.'linkerd.io/inject' -eq 'enabled') -and
						 ($postgresDeployment.spec.template.metadata.annotations.'linkerd.io/inject' -eq 'enabled')
		if (-not $hasAnnotations) {
			Write-Log "Waiting for patches to be applied (attempt $attempt of $maxAttempts)..."
			Start-Sleep -Seconds 2
		}
	} while (-not $hasAnnotations -and $attempt -lt $maxAttempts)

	if (-not $hasAnnotations) {
		throw "Timeout waiting for patches to be applied"
	}
} else {
	Write-Log "Updating dicom addon to not be part of service mesh"
	$annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config.linkerd.io/opaque-ports\":null,\"linkerd.io/inject\":null}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'dicom', '-n', 'dicom', '-p', $annotations).Output | Write-Log
	(Invoke-Kubectl -Params 'patch', 'deployment', 'postgres', '-n', 'dicom', '-p', $annotations).Output | Write-Log

	$maxAttempts = 30
	$attempt = 0
	do {
		$attempt++
		$dicomDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'dicom', '-n', 'dicom', '-o', 'json').Output | ConvertFrom-Json
		$postgresDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'postgres', '-n', 'dicom', '-o', 'json').Output | ConvertFrom-Json
		$hasNoAnnotations = ($null -eq $dicomDeployment.spec.template.metadata.annotations.'linkerd.io/inject') -and
						   ($null -eq $postgresDeployment.spec.template.metadata.annotations.'linkerd.io/inject')
		if (-not $hasNoAnnotations) {
			Write-Log "Waiting for patches to be applied (attempt $attempt of $maxAttempts)..."
			Start-Sleep -Seconds 2
		}
	} while (-not $hasNoAnnotations -and $attempt -lt $maxAttempts)

	if (-not $hasNoAnnotations) {
		throw "Timeout waiting for patches to be applied"
	}
}
(Invoke-Kubectl -Params 'rollout', 'status', 'deployment', '-n', 'dicom', '--timeout', '60s').Output | Write-Log


