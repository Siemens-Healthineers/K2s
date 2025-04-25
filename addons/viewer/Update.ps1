# SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$viewerModule = "$PSScriptRoot\viewer.module.psm1"

Import-Module $addonsModule, $viewerModule

Update-IngressForAddon -Addon ([pscustomobject] @{Name = 'viewer' })
Update-ViewerConfigMap

$EnancedSecurityEnabled = Test-LinkerdServiceAvailability
if ($EnancedSecurityEnabled) {
    Write-Log "Updating viewer addon to be part of service mesh"  
    $annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\"}}}}}'
    (Invoke-Kubectl -Params 'patch', 'deployment', 'viewerwebapp', '-n', 'viewer', '-p', $annotations).Output | Write-Log
} else {
    Write-Log "Updating viewer addon to not be part of service mesh"
    $annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config.linkerd.io/skip-inbound-ports\":null,\"linkerd.io/inject\":null}}}}}'
    (Invoke-Kubectl -Params 'patch', 'deployment', 'viewerwebapp', '-n', 'viewer', '-p', $annotations).Output | Write-Log
}
(Invoke-Kubectl -Params 'rollout', 'status', 'deployment', '-n', 'viewer', '--timeout', '60s').Output | Write-Log

Write-Log 'Updating viewer addon finished.' -Console