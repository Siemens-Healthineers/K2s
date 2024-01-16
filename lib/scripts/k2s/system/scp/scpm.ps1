# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Copies files from and to the Kubemaster

.DESCRIPTION
Copies files from the host machine to Kubemaster and vice-versa

.PARAMETER Source
File/Folder to be copied

.PARAMETER Target
Destination where the file/folder needs to be copied to.

.PARAMETER Reverse
If set, the files are copied from the Kubemaster VM to the host machine

.EXAMPLE
# Copy files from host machine to Kubemaster VM
PS> .\scpm.ps1 -Source C:\temp.txt -Target /tmp

.EXAMPLE
# Copy files from Kubemaster VM to the host machine
PS> .\scpm.ps1 -Source /tmp/temp.txt -Target C:\temp -Reverse
#>

Param (
    [parameter(Mandatory = $true, HelpMessage = 'File/Folder to be copied')]
    [string]$Source,

    [parameter(Mandatory = $true, HelpMessage = 'Destination where the file/fodler needs to be copied to')]
    [string]$Target,

    [parameter(Mandatory = $false, HelpMessage = 'If set, the files are coped from the Kubemaster VM to the host machone')]
    [switch]$Reverse
)

$infraModule = "$PSScriptRoot/../../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot/../../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule

Test-ClusterAvailability

if (!$Reverse) {
    Copy-ToControlPlaneViaSSHKey -Source:$Source -Target:$Target -IgnoreErrors
}
else {
    Copy-FromControlPlaneViaSSHKey -Source:$Source -Target:$Target -IgnoreErrors
}
