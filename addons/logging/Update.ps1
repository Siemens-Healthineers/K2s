<<<<<<< HEAD
# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
=======
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
>>>>>>> origin/main
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$loggingModule = "$PSScriptRoot\logging.module.psm1"

Import-Module $addonsModule, $loggingModule

<<<<<<< HEAD
Update-IngressForAddon -Addon ([pscustomobject] @{Name = 'logging' })
=======
$loggingConfig = Get-AddonConfig -Name 'logging'
$omitOpensearch = $loggingConfig.OmitOpensearch -eq $true

if (-not $omitOpensearch) {
    Update-IngressForAddon -Addon ([pscustomobject] @{Name = 'logging' })
}
>>>>>>> origin/main

$EnancedSecurityEnabled = Test-LinkerdServiceAvailability
if ($EnancedSecurityEnabled) {
    Write-Log "Updating logging addon to be part of service mesh"  
<<<<<<< HEAD
    $annotations1 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/skip-inbound-ports\":\"9200\"}}}}}'
    (Invoke-Kubectl -Params 'patch', 'statefulset', 'opensearch-cluster-master', '-n', 'logging', '-p', $annotations1).Output | Write-Log
    $annotations2 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\"}}}}}'
    (Invoke-Kubectl -Params 'patch', 'deployment', 'opensearch-dashboards', '-n', 'logging', '-p', $annotations2).Output | Write-Log
=======
    if (-not $omitOpensearch) {
        $annotations1 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/skip-inbound-ports\":\"9200\"}}}}}'
        (Invoke-Kubectl -Params 'patch', 'statefulset', 'opensearch-cluster-master', '-n', 'logging', '-p', $annotations1).Output | Write-Log
        $annotations2 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\"}}}}}'
        (Invoke-Kubectl -Params 'patch', 'deployment', 'opensearch-dashboards', '-n', 'logging', '-p', $annotations2).Output | Write-Log
    }
>>>>>>> origin/main
    $annotations3 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/skip-outbound-ports\":\"9200\"}}}}}'
    (Invoke-Kubectl -Params 'patch', 'daemonset', 'fluent-bit', '-n', 'logging', '-p', $annotations3).Output | Write-Log

    $maxAttempts = 30
    $attempt = 0
    do {
        $attempt++
<<<<<<< HEAD
        $statefulset = (Invoke-Kubectl -Params 'get', 'statefulset', 'opensearch-cluster-master', '-n', 'logging', '-o', 'json').Output | ConvertFrom-Json
        $deployment = (Invoke-Kubectl -Params 'get', 'deployment', 'opensearch-dashboards', '-n', 'logging', '-o', 'json').Output | ConvertFrom-Json
        $daemonset = (Invoke-Kubectl -Params 'get', 'daemonset', 'fluent-bit', '-n', 'logging', '-o', 'json').Output | ConvertFrom-Json
        
        $hasAnnotations = ($statefulset.spec.template.metadata.annotations.'linkerd.io/inject' -eq 'enabled') -and
                         ($deployment.spec.template.metadata.annotations.'linkerd.io/inject' -eq 'enabled') -and
                         ($daemonset.spec.template.metadata.annotations.'linkerd.io/inject' -eq 'enabled')
=======
        $daemonset = (Invoke-Kubectl -Params 'get', 'daemonset', 'fluent-bit', '-n', 'logging', '-o', 'json').Output | ConvertFrom-Json

        if (-not $omitOpensearch) {
            $statefulset = (Invoke-Kubectl -Params 'get', 'statefulset', 'opensearch-cluster-master', '-n', 'logging', '-o', 'json').Output | ConvertFrom-Json
            $deployment = (Invoke-Kubectl -Params 'get', 'deployment', 'opensearch-dashboards', '-n', 'logging', '-o', 'json').Output | ConvertFrom-Json
            $hasAnnotations = ($statefulset.spec.template.metadata.annotations.'linkerd.io/inject' -eq 'enabled') -and
                             ($deployment.spec.template.metadata.annotations.'linkerd.io/inject' -eq 'enabled') -and
                             ($daemonset.spec.template.metadata.annotations.'linkerd.io/inject' -eq 'enabled')
        } else {
            $hasAnnotations = ($daemonset.spec.template.metadata.annotations.'linkerd.io/inject' -eq 'enabled')
        }
>>>>>>> origin/main
        if (-not $hasAnnotations) {
            Write-Log "Waiting for patches to be applied (attempt $attempt of $maxAttempts)..."
            Start-Sleep -Seconds 2
        }
    } while (-not $hasAnnotations -and $attempt -lt $maxAttempts)

    if (-not $hasAnnotations) {
        throw "Timeout waiting for patches to be applied"
    }
} else {
	Write-Log "Updating logging addon to not be part of service mesh"
	$annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config.linkerd.io/skip-inbound-ports\":null,\"config.linkerd.io/skip-outbound-ports\":null,\"linkerd.io/inject\":null}}}}}'
<<<<<<< HEAD
	(Invoke-Kubectl -Params 'patch', 'statefulset', 'opensearch-cluster-master', '-n', 'logging', '-p', $annotations).Output | Write-Log
	(Invoke-Kubectl -Params 'patch', 'deployment', 'opensearch-dashboards', '-n', 'logging', '-p', $annotations).Output | Write-Log
=======
	if (-not $omitOpensearch) {
		(Invoke-Kubectl -Params 'patch', 'statefulset', 'opensearch-cluster-master', '-n', 'logging', '-p', $annotations).Output | Write-Log
		(Invoke-Kubectl -Params 'patch', 'deployment', 'opensearch-dashboards', '-n', 'logging', '-p', $annotations).Output | Write-Log
	}
>>>>>>> origin/main
	(Invoke-Kubectl -Params 'patch', 'daemonset', 'fluent-bit', '-n', 'logging', '-p', $annotations).Output | Write-Log

	$maxAttempts = 30
	$attempt = 0
	do {
		$attempt++
<<<<<<< HEAD
		$statefulset = (Invoke-Kubectl -Params 'get', 'statefulset', 'opensearch-cluster-master', '-n', 'logging', '-o', 'json').Output | ConvertFrom-Json
		$deployment = (Invoke-Kubectl -Params 'get', 'deployment', 'opensearch-dashboards', '-n', 'logging', '-o', 'json').Output | ConvertFrom-Json
		$daemonset = (Invoke-Kubectl -Params 'get', 'daemonset', 'fluent-bit', '-n', 'logging', '-o', 'json').Output | ConvertFrom-Json
		
		$hasNoAnnotations = ($null -eq $statefulset.spec.template.metadata.annotations.'linkerd.io/inject') -and
						   ($null -eq $deployment.spec.template.metadata.annotations.'linkerd.io/inject') -and
						   ($null -eq $daemonset.spec.template.metadata.annotations.'linkerd.io/inject')
=======
		$daemonset = (Invoke-Kubectl -Params 'get', 'daemonset', 'fluent-bit', '-n', 'logging', '-o', 'json').Output | ConvertFrom-Json

		if (-not $omitOpensearch) {
			$statefulset = (Invoke-Kubectl -Params 'get', 'statefulset', 'opensearch-cluster-master', '-n', 'logging', '-o', 'json').Output | ConvertFrom-Json
			$deployment = (Invoke-Kubectl -Params 'get', 'deployment', 'opensearch-dashboards', '-n', 'logging', '-o', 'json').Output | ConvertFrom-Json
			$hasNoAnnotations = ($null -eq $statefulset.spec.template.metadata.annotations.'linkerd.io/inject') -and
							   ($null -eq $deployment.spec.template.metadata.annotations.'linkerd.io/inject') -and
							   ($null -eq $daemonset.spec.template.metadata.annotations.'linkerd.io/inject')
		} else {
			$hasNoAnnotations = ($null -eq $daemonset.spec.template.metadata.annotations.'linkerd.io/inject')
		}
>>>>>>> origin/main
		if (-not $hasNoAnnotations) {
			Write-Log "Waiting for patches to be applied (attempt $attempt of $maxAttempts)..."
			Start-Sleep -Seconds 2
		}
	} while (-not $hasNoAnnotations -and $attempt -lt $maxAttempts)

	if (-not $hasNoAnnotations) {
		throw "Timeout waiting for patches to be applied"
	}
}
<<<<<<< HEAD
(Invoke-Kubectl -Params 'rollout', 'status', 'deployment', '-n', 'logging', '--timeout', '60s').Output | Write-Log
(Invoke-Kubectl -Params 'rollout', 'status', 'statefulset', '-n', 'logging', '--timeout', '60s').Output | Write-Log
=======
if (-not $omitOpensearch) {
    (Invoke-Kubectl -Params 'rollout', 'status', 'deployment', '-n', 'logging', '--timeout', '60s').Output | Write-Log
    (Invoke-Kubectl -Params 'rollout', 'status', 'statefulset', '-n', 'logging', '--timeout', '60s').Output | Write-Log
}
>>>>>>> origin/main
(Invoke-Kubectl -Params 'rollout', 'status', 'daemonset', '-n', 'logging', '--timeout', '60s').Output | Write-Log

Write-Log 'Updating logging addon finished.' -Console