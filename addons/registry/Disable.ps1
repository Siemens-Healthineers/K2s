# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Disables k2s.registry in the cluster

.DESCRIPTION
The local regsitry allows to push/pull images to/from the local volume of KubeMaster.
Each node inside the cluster can connect to the registry.

.EXAMPLE
# For k2sSetup
powershell <installation folder>\addons\registry\Disable.ps1
#>

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Delete local image storage')]
    [switch] $DeleteImages = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$nodeModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.node.module/k2s.node.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$registryModule = "$PSScriptRoot\registry.module.psm1"

Import-Module $infraModule, $clusterModule, $nodeModule, $addonsModule, $registryModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Checking cluster status' -Console

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

Write-Log 'Check whether registry addon is already disabled'

if ($null -eq (Invoke-Kubectl -Params 'get', 'namespace', 'registry', '--ignore-not-found').Output -and (Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'registry' })) -ne $true) {
    $errMsg = "Addon 'registry' is already disabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyDisabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Uninstalling Kubernetes registry' -Console

Remove-IngressForTraefik -Addon ([pscustomobject] @{Name = 'registry' })
Remove-IngressForNginx -Addon ([pscustomobject] @{Name = 'registry' })
(Invoke-Kubectl -Params 'delete', '-k', "$PSScriptRoot\manifests\registry").Output | Write-Log
(Invoke-Kubectl -Params 'delete', 'namespace', 'registry').Output | Write-Log

if ($DeleteImages) {
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo rm -rf /registry').Output | Write-Log
}

Remove-InsecureRegistry

Remove-AddonFromSetupJson -Addon ([pscustomobject] @{Name = 'registry' })
Remove-RegistryFromSetupJson -Name 'k2s.registry.local*' -IsRegex $true

Write-Log 'Uninstallation of Kubernetes registry finished' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}