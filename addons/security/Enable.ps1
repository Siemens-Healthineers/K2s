# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs secure communication

.DESCRIPTION
Enables secure communication into and inside the cluster. This includes:
- certificate provisioning and renewal, for TLS termination and service meshes

.EXAMPLE
Enable security in k2s
powershell <installation folder>\addons\security\Enable.ps1
#>

[CmdletBinding(SupportsShouldProcess = $true)]
Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1
. $PSScriptRoot\Common.ps1

$logModule = "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"

Import-Module $logModule, $addonsModule, $clusterModule, $infraModule

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

if ((Test-IsAddonEnabled -Name 'security') -eq $true) {
    $errMsg = "Addon 'security' is already enabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Downloading cert-manager files' -Console
$manifest = Get-FromYamlFile -Path "$PSScriptRoot\addon.manifest.yaml"
$k2sRoot = "$PSScriptRoot\..\.."
$windowsCurlPackages = $manifest.spec.offline_usage.windows.curl
if ($windowsCurlPackages) {
    foreach ($package in $windowsCurlPackages) {
        $destination = $package.destination
        $destination = "$k2sRoot\$destination"
        if (!(Test-Path $destination)) {
            $url = $package.url
            Write-Log "Downloading $url TO $destination"
            DownloadFile $destination $url $true -ProxyToUse $Proxy
        }
        else {
            Write-Log "File $destination already exists. Skipping download."
        }
    }
}

Write-Log 'Installing cert-manager' -Console
$certManagerConfig = Get-CertManagerConfig
&$global:KubectlExe apply -f $certManagerConfig

Write-Log 'Waiting for cert-manager APIs to be ready, be patient!' -Console
$certManagerStatus = Wait-ForCertManagerAvailable

if ($certManagerStatus -ne $true) {
    $errMsg = "cert-manager is not ready. Please use cmctl.exe to investigate.`nInstallation of 'security' addon failed."
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Configuring CA ClusterIssuer' -Console
$caIssuerConfig = Get-CAIssuerConfig
&$global:KubectlExe apply -f $caIssuerConfig

Write-Log 'Waiting for CA root certificate to be created' -Console
$caCreated = Wait-ForCARootCertificate

if ($caCreated -ne $true) {
    $errMsg = "CA root certificate 'ca-issuer-root-secret' not found.`nInstallation of 'security' addon failed."
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Importing CA root certificate to trusted authorities of your computer' -Console
$b64secret = &$global:KubectlExe -n cert-manager get secrets ca-issuer-root-secret -o jsonpath --template '{.data.ca\.crt}'
[Text.Encoding]::Utf8.GetString([Convert]::FromBase64String($b64secret)) | Out-File -Encoding utf8 C:\Temp\ca-root-secret.crt
certutil -addstore -f -enterprise -user root C:\Temp\ca-root-secret.crt
Remove-Item C:\Temp\ca-root-secret.crt

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'security' })

Write-Log 'Installation of security finished.' -Console

Write-UsageForUser
Write-WarningForUser

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}