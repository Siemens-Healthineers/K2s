# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
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
$monitoringModule = "$PSScriptRoot\monitoring.module.psm1"

Import-Module $clusterModule, $infraModule, $addonsModule, $monitoringModule

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

Write-Log 'Check whether monitoring addon is already disabled'

if ($null -eq (Invoke-Kubectl -Params 'get', 'namespace', 'monitoring', '--ignore-not-found').Output -and (Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'monitoring' })) -ne $true) {
    $errMsg = "Addon 'monitoring' is already disabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyDisabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

$manifestsPath = "$PSScriptRoot\manifests\monitoring"

Write-Log 'Uninstalling Kube Prometheus Stack' -Console
Remove-IngressForTraefik -Addon ([pscustomobject] @{Name = 'monitoring' })
Remove-IngressForNginx -Addon ([pscustomobject] @{Name = 'monitoring' })
(Invoke-Kubectl -Params 'delete', '-k', $manifestsPath).Output | Write-Log
(Invoke-Kubectl -Params 'delete', '-f', "$manifestsPath\crds").Output | Write-Log
(Invoke-Kubectl -Params 'delete', '-f', "$manifestsPath\namespace.yaml").Output | Write-Log

# Check if Windows Exporter is still needed by other addons
$metricsEnabled = Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'metrics' })

Remove-AddonFromSetupJson -Addon ([pscustomobject] @{Name = 'monitoring' })

if (-not $metricsEnabled) {
    Write-Log 'Removing Windows Exporter (no longer needed by any addon)' -Console
    $windowsExporterManifest = Get-WindowsExporterManifestDir
    (Invoke-Kubectl -Params 'delete', '-k', $windowsExporterManifest, '--ignore-not-found').Output | Write-Log
} else {
    Write-Log 'Windows Exporter kept (still needed by metrics addon)' -Console
}

Write-Log 'Kube Prometheus Stack uninstalled successfully' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}