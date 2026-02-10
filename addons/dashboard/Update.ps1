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

$SecurityAddonEnabled = Test-SecurityAddonAvailability
if ($SecurityAddonEnabled) {
	Write-Log 'Security addon is enabled'
	if (Test-NginxIngressControllerAvailability) {
		# patch ingress to remove annotations
		Write-Log 'Patching ingress to remove annotations'
		$annotations = '{\"metadata\":{\"annotations\":{\"nginx.ingress.kubernetes.io/configuration-snippet\":null}}}'
		(Invoke-Kubectl -Params 'patch', 'ingress', 'dashboard-nginx-cluster-local', '-n', 'dashboard', '-p', $annotations).Output | Write-Log
	}
	elseif (Test-TraefikIngressControllerAvailability) {
		# remove middleware if exists
		(Invoke-Kubectl -Params 'delete', 'middleware', 'add-bearer-token', '-n', 'dashboard', '--ignore-not-found').Output | Write-Log
	}
	elseif (Test-NginxGatewayAvailability) {
		# Create kong CA certificate ConfigMap for BackendTLSPolicy validation
		Write-Log 'Configuring BackendTLSPolicy certificate validation for nginx-gw with security addon' -Console
		New-KongCACertConfigMap
	}
	else {
		Write-Log 'Nginx, Traefik, or Gateway Fabric API ingress controller is not available'
	}	
}
else {
	if (Test-NginxIngressControllerAvailability) {
		# create Bearer token for next 24h
		Write-Log 'Creating Bearer token for next 24h'
		$token = Get-BearerToken
		# copy patch template to temp folder
		$tempPath = [System.IO.Path]::GetTempPath()
		Copy-Item -Path "$PSScriptRoot\manifests\ingress-nginx\patch.json" -Destination "$tempPath\patch.json"
		# replace content of file
		Write-Log 'Replacing content of patch file'
		(Get-Content -Path "$tempPath\patch.json").replace('BEARER-TOKEN', $token) | Out-File -FilePath "$tempPath\patch.json"
		# apply patch
		(Invoke-Kubectl -Params 'patch', 'ingress', 'dashboard-nginx-cluster-local', '-n', 'dashboard', '--patch-file', "$tempPath\patch.json").Output | Write-Log
		# delete patch file
		Remove-Item -Path "$tempPath\patch.json"
	}
	elseif (Test-TraefikIngressControllerAvailability) {
		# create Bearer token for next 24h
		Write-Log 'Creating Bearer token for next 24h'
		$token = Get-BearerToken
		# create middleware, be aware of special characters !
		$middleware = "apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
 name: add-bearer-token
 namespace: dashboard
spec:
 headers:
  customRequestHeaders: 
   Authorization: Bearer $token"

		$tempPath = [System.IO.Path]::GetTempPath()
		$middleware | Out-File -FilePath "$tempPath\middleware.yaml" -Encoding ascii
		(Invoke-Kubectl -Params 'apply', '-f', "$tempPath\middleware.yaml", '-n', 'dashboard').Output | Write-Log
		# delete middleware file
		Remove-Item -Path "$tempPath\middleware.yaml"
	}
	elseif (Test-NginxGatewayAvailability) {
		# Create kong CA certificate ConfigMap for BackendTLSPolicy validation
		Write-Log 'Configuring BackendTLSPolicy certificate validation for nginx-gw' -Console
		New-KongCACertConfigMap
		
		# create Bearer token for next 24h
		Write-Log 'Creating Bearer token for next 24h'
		$token = Get-BearerToken
		# Apply HTTPRoute with Authorization header using template
		Write-Log 'Applying HTTPRoute with Authorization header'
		$tempPath = [System.IO.Path]::GetTempPath()
		Copy-Item -Path "$PSScriptRoot\manifests\ingress-nginx-gw\dashboard-nginx-gw.yaml" -Destination "$tempPath\dashboard-nginx-gw.yaml"
		(Get-Content -Path "$tempPath\dashboard-nginx-gw.yaml").replace('BEARER-TOKEN', $token) | Out-File -FilePath "$tempPath\dashboard-nginx-gw.yaml"
		(Invoke-Kubectl -Params 'apply', '-f', "$tempPath\dashboard-nginx-gw.yaml").Output | Write-Log
		Remove-Item -Path "$tempPath\dashboard-nginx-gw.yaml"
	}
	else {
		Write-Log 'Nginx, Traefik, or Gateway Fabric API ingress controller is not available'
	}
}

$EnancedSecurityEnabled = Test-LinkerdServiceAvailability
if ($EnancedSecurityEnabled) {
	Write-Log 'Updating dashboard addon to be part of service mesh'  
	$annotations1 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/skip-inbound-ports\":\"443\"}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'kubernetes-dashboard-kong', '-n', 'dashboard', '-p', $annotations1).Output | Write-Log
	$annotations2 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\"}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'kubernetes-dashboard-api', '-n', 'dashboard', '-p', $annotations2).Output | Write-Log
	$annotations3 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\"}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'kubernetes-dashboard-auth', '-n', 'dashboard', '-p', $annotations3).Output | Write-Log
	$annotations4 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/skip-inbound-ports\":\"8000\"}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'kubernetes-dashboard-metrics-scraper', '-n', 'dashboard', '-p', $annotations4).Output | Write-Log
	$annotations5 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\"}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'kubernetes-dashboard-web', '-n', 'dashboard', '-p', $annotations5).Output | Write-Log

	$maxAttempts = 30
	$attempt = 0
	do {
		$attempt++
		$kongDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'kubernetes-dashboard-kong', '-n', 'dashboard', '-o', 'json').Output | ConvertFrom-Json
		$apiDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'kubernetes-dashboard-api', '-n', 'dashboard', '-o', 'json').Output | ConvertFrom-Json
		$authDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'kubernetes-dashboard-auth', '-n', 'dashboard', '-o', 'json').Output | ConvertFrom-Json
		$metricsDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'kubernetes-dashboard-metrics-scraper', '-n', 'dashboard', '-o', 'json').Output | ConvertFrom-Json
		$webDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'kubernetes-dashboard-web', '-n', 'dashboard', '-o', 'json').Output | ConvertFrom-Json

		$hasAnnotations = ($kongDeployment.spec.template.metadata.annotations.'linkerd.io/inject' -eq 'enabled') -and
						 ($apiDeployment.spec.template.metadata.annotations.'linkerd.io/inject' -eq 'enabled') -and
						 ($authDeployment.spec.template.metadata.annotations.'linkerd.io/inject' -eq 'enabled') -and
						 ($metricsDeployment.spec.template.metadata.annotations.'linkerd.io/inject' -eq 'enabled') -and
						 ($webDeployment.spec.template.metadata.annotations.'linkerd.io/inject' -eq 'enabled')
		if (-not $hasAnnotations) {
			Write-Log "Waiting for patches to be applied (attempt $attempt of $maxAttempts)..."
			Start-Sleep -Seconds 2
		}
	} while (-not $hasAnnotations -and $attempt -lt $maxAttempts)

	if (-not $hasAnnotations) {
		throw 'Timeout waiting for patches to be applied'
	}
}
else {
	Write-Log 'Updating dashboard addon to not be part of service mesh'
	$annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config.linkerd.io/skip-inbound-ports\":null,\"linkerd.io/inject\":null}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'kubernetes-dashboard-kong', '-n', 'dashboard', '-p', $annotations).Output | Write-Log
	(Invoke-Kubectl -Params 'patch', 'deployment', 'kubernetes-dashboard-api', '-n', 'dashboard', '-p', $annotations).Output | Write-Log
	(Invoke-Kubectl -Params 'patch', 'deployment', 'kubernetes-dashboard-auth', '-n', 'dashboard', '-p', $annotations).Output | Write-Log
	(Invoke-Kubectl -Params 'patch', 'deployment', 'kubernetes-dashboard-metrics-scraper', '-n', 'dashboard', '-p', $annotations).Output | Write-Log
	(Invoke-Kubectl -Params 'patch', 'deployment', 'kubernetes-dashboard-web', '-n', 'dashboard', '-p', $annotations).Output | Write-Log

	$maxAttempts = 30
	$attempt = 0
	do {
		$attempt++
		$kongDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'kubernetes-dashboard-kong', '-n', 'dashboard', '-o', 'json').Output | ConvertFrom-Json
		$apiDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'kubernetes-dashboard-api', '-n', 'dashboard', '-o', 'json').Output | ConvertFrom-Json
		$authDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'kubernetes-dashboard-auth', '-n', 'dashboard', '-o', 'json').Output | ConvertFrom-Json
		$metricsDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'kubernetes-dashboard-metrics-scraper', '-n', 'dashboard', '-o', 'json').Output | ConvertFrom-Json
		$webDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'kubernetes-dashboard-web', '-n', 'dashboard', '-o', 'json').Output | ConvertFrom-Json

		$hasNoAnnotations = ($null -eq $kongDeployment.spec.template.metadata.annotations.'linkerd.io/inject') -and
						   ($null -eq $apiDeployment.spec.template.metadata.annotations.'linkerd.io/inject') -and
						   ($null -eq $authDeployment.spec.template.metadata.annotations.'linkerd.io/inject') -and
						   ($null -eq $metricsDeployment.spec.template.metadata.annotations.'linkerd.io/inject') -and
						   ($null -eq $webDeployment.spec.template.metadata.annotations.'linkerd.io/inject')
		if (-not $hasNoAnnotations) {
			Write-Log "Waiting for patches to be applied (attempt $attempt of $maxAttempts)..."
			Start-Sleep -Seconds 2
		}
	} while (-not $hasNoAnnotations -and $attempt -lt $maxAttempts)

	if (-not $hasNoAnnotations) {
		throw 'Timeout waiting for patches to be applied'
	}
}
(Invoke-Kubectl -Params 'rollout', 'status', 'deployment', '-n', 'dashboard', '--timeout', '60s').Output | Write-Log

Write-Log 'Updating dashboard addon finished.' -Console