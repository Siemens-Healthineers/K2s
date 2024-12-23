# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Disables Prometheus/Grafana monitoring features for the k2s cluster.

.DESCRIPTION
The "monitoring" addons enables Prometheus/Grafana monitoring features for the k2s cluster.
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$dicomModule = "$PSScriptRoot\dicom.module.psm1"
$viewerModule = "$PSScriptRoot\..\viewer\viewer.module.psm1"

Import-Module $clusterModule, $infraModule, $addonsModule, $dicomModule, $viewerModule

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

Write-Log 'Check whether dicom addon is already disabled'

if ($null -eq (Invoke-Kubectl -Params 'get', 'namespace', 'dicom', '--ignore-not-found').Output -and (Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'dicom' })) -ne $true) {
    $errMsg = "Addon 'dicom' is already disabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyDisabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

$dicomConfig = Get-DicomConfig

Write-Log 'Uninstalling dicom server' -Console
Remove-IngressForTraefik -Addon ([pscustomobject] @{Name = 'dicom' })
Remove-IngressForNginx -Addon ([pscustomobject] @{Name = 'dicom' })
(Invoke-Kubectl -Params 'delete', '-k', $dicomConfig).Output | Write-Log
(Invoke-Kubectl -Params 'delete', '-f', "$dicomConfig\dicom-namespace.yaml").Output | Write-Log

Remove-AddonFromSetupJson -Addon ([pscustomobject] @{Name = 'dicom' })
# adapt other addons
Update-Addons

Write-Log 'dicom server uninstalled successfully' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}