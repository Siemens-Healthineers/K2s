# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Uninstalls ingress nginx-gw from the cluster

.DESCRIPTION
Ingress nginx-gw is using k8s load balancer and is bound to the IP of the master machine.
It allows applications to register their ingress nginx gateway resources and handles incomming HTTP/HTPPS traffic.

.EXAMPLE
powershell <installation folder>\addons\ingress\nginx-gw\Disable.ps1
#>

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$clusterModule = "$PSScriptRoot/../../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$infraModule = "$PSScriptRoot/../../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"
$gatewayModule = "$PSScriptRoot\nginx-gw.module.psm1"

Import-Module $clusterModule, $infraModule, $addonsModule, $gatewayModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Checking cluster status' -Console

# get addon name from folder path
$addonName = Get-AddonNameFromFolderPath -BaseFolderPath $PSScriptRoot

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

Write-Log 'Check whether ingress nginx gateway fabric addon is already disabled'

if ($null -eq (Invoke-Kubectl -Params 'get', 'namespace', 'nginx-gw', '--ignore-not-found').Output -and (Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'ingress'; Implementation = 'nginx-gw' })) -ne $true) {
    $errMsg = "Addon 'ingress nginx gateway fabric' is already disabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyDisabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Uninstalling ingress nginx gateway fabric' -Console
$clusterNginxGatewayConfig = "$PSScriptRoot\manifests\cluster-local-nginx-gw.yaml"
(Invoke-Kubectl -Params 'delete' , '-f', $clusterNginxGatewayConfig).Output | Write-Log

$CrdsDirectory = Get-NginxGatewayCrdsDir
(Invoke-Kubectl -Params 'delete', '-f', $CrdsDirectory).Output | Write-Log

$nginxGatewayYamlDir = Get-NginxGatewayYamlDir
(Invoke-Kubectl -Params 'delete', '-k', $nginxGatewayYamlDir, '--ignore-not-found').Output | Write-Log

(Invoke-Kubectl -Params 'delete', 'namespace', 'nginx-gw', '--ignore-not-found').Output | Write-Log

Write-log 'Uninstalling ExternalDNS' -Console
$externalDnsConfigDir = Get-ExternalDnsConfigDir
(Invoke-Kubectl -Params 'delete', '-k', $externalDnsConfigDir).Output | Write-Log

Uninstall-CertManager

Uninstall-GatewayApiCrds

Remove-AddonFromSetupJson -Addon ([pscustomobject] @{Name = 'ingress'; Implementation = 'nginx-gw' })

# adapt other addons
Update-Addons -AddonName $addonName

Write-Log 'Uninstallation of ingress nginx-gw-fabric addon finished' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}