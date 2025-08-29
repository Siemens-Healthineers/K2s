# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Uninstalls security

.DESCRIPTION

.EXAMPLE
Disable security addon
powershell <installation folder>\addons\security\Disable.ps1
#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$securityModule = "$PSScriptRoot\security.module.psm1"
$linuxNodeModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.node.module/linuxnode/vm/vm.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule, $securityModule, $linuxNodeModule
Import-Module PKI;

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

if ($null -eq (Invoke-Kubectl -Params 'get', 'namespace', 'cert-manager', '--ignore-not-found').Output -and (Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'security' })) -ne $true) {
    $errMsg = "Addon 'security' is already disabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyDisabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Uninstalling security cert manager parts' -Console
$certManagerConfig = Get-CertManagerConfig
$caIssuerConfig = Get-CAIssuerConfig

(Invoke-Kubectl -Params 'delete', '--ignore-not-found', '--timeout=30s', '-f', $caIssuerConfig).Output | Write-Log
(Invoke-Kubectl -Params 'delete', '--ignore-not-found', '--timeout=30s', '-f', $certManagerConfig).Output | Write-Log

Remove-Cmctl

Write-Log 'Removing CA issuer certificate from trusted root' -Console
$caIssuerName = Get-CAIssuerName
$trustedRootStoreLocation = Get-TrustedRootStoreLocation
Get-ChildItem -Path $trustedRootStoreLocation | Where-Object { $_.Subject -match $caIssuerName } | Remove-Item

$oauth2ProxyYaml = Get-OAuth2ProxyConfig
(Invoke-Kubectl -Params 'delete', '--ignore-not-found', '-f', $oauth2ProxyYaml).Output | Write-Log

$oauth2ProxyHydraYaml = Get-OAuth2ProxyHydraConfig  
(Invoke-Kubectl -Params 'delete', '--ignore-not-found', '-f', $oauth2ProxyHydraYaml).Output | Write-Log

$keyCloakYaml = Get-KeyCloakConfig
(Invoke-Kubectl -Params 'delete', '--ignore-not-found', '-f',$keyCloakYaml).Output | Write-Log

$keyCloakPostgresYaml = Get-KeyCloakPostgresConfig
(Invoke-Kubectl -Params 'delete', '--ignore-not-found', '-f', $keyCloakPostgresYaml).Output | Write-Log

Remove-WindowsSecurityDeployments

$linkerdYaml = Get-LinkerdConfigDirectory
(Invoke-Kubectl -Params 'delete', '--ignore-not-found', '-k',$linkerdYaml).Output | Write-Log

Remove-LinkerdMarkerConfig

Remove-LinkerdExecutable

$linkerdYamlCNI = Get-LinkerdConfigCNI
(Invoke-Kubectl -Params 'delete', '--ignore-not-found', '-f',$linkerdYamlCNI).Output | Write-Log

$linkerdYamlCertManager = Get-LinkerdConfigCertManager
(Invoke-Kubectl -Params 'delete', '--ignore-not-found', '-f', $linkerdYamlCertManager).Output | Write-Log

$linkerdYamlTrustManager = Get-LinkerdConfigTrustManager
(Invoke-Kubectl -Params 'delete', '--ignore-not-found', '-f', $linkerdYamlTrustManager).Output | Write-Log

Remove-ConfigFileForCNI

Remove-LinkerdManifests 

Write-Log 'Deleting old storage files for postgres' -Console
(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo rm -rf /mnt/keycloak').Output | Write-Log

Remove-AddonFromSetupJson -Addon ([pscustomobject] @{Name = 'security' })

# if security addon is enabled, than adapt other addons
# Important is that update is called at the end because addons check state of security addon
Update-Addons -AddonName $addonName

Write-Log 'Uninstallation of security finished' -Console

Write-SecurityWarningForUser

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}