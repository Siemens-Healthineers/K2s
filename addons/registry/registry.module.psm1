# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$k8sApiModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k8s-api/k8s-api.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.node.module\k2s.node.module.psm1"

Import-Module $infraModule, $k8sApiModule, $nodeModule

function Restart-Services() {
    Write-Log 'Restarting services' -Console
    Stop-NssmService('kubeproxy')
    Stop-NssmService('kubelet')
    Restart-NssmService('containerd')
    Start-NssmService('kubelet')
    Start-NssmService('kubeproxy')
}


<#
.DESCRIPTION
Writes the usage notes for dashboard for the user.
#>
function Write-RegistryUsageForUser {
    param(
        [Parameter()]
        [String]
        $Name
    )
    @"
                                        USAGE NOTES
 Registry is available via '$Name'
 
 In order to push your images to the private registry you have to tag your images as in the following example:
 $Name/<yourImageName>:<yourImageTag>
"@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
}

function Update-NodePort {
    Write-Log "  Applying nodeport service manifest for registry..." -Console
    (Invoke-Kubectl -Params 'apply', '-f', "$PSScriptRoot\manifests\registry\service-nodeport.yaml").Output | Write-Log
}

function Remove-NodePort {
    Write-Log "  Removing nodeport service manifest for registry..." -Console
    (Invoke-Kubectl -Params 'delete', '-f', "$PSScriptRoot\manifests\registry\service-nodeport.yaml", "--ignore-not-found").Output | Write-Log
}