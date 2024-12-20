# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
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
    [parameter(Mandatory = $false, HelpMessage = 'Enable ingress addon')]
    [ValidateSet('nginx', 'traefik')]
    [string] $Ingress = 'nginx',
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$securityModule = "$PSScriptRoot\security.module.psm1"

# TODO: Remove cross referencing once the code clones are removed and use the central module for these functions.
$loggingModule = "$PSScriptRoot\..\logging\logging.module.psm1"

Import-Module $infraModule, $clusterModule, $nodeModule, $addonsModule, $securityModule, $loggingModule
Import-Module PKI;

Initialize-Logging -ShowLogs:$ShowLogs

$Proxy = Get-OrUpdateProxyServer -Proxy:$Proxy

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

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'security' })) -eq $true) {
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
$windowsCurlPackages = $manifest.spec.implementations[0].offline_usage.windows.curl
if ($windowsCurlPackages) {
    foreach ($package in $windowsCurlPackages) {
        $destination = $package.destination
        $destination = "$k2sRoot\$destination"
        if (!(Test-Path $destination)) {
            $url = $package.url
            Invoke-DownloadFile $destination $url $true -ProxyToUse $Proxy
        }
        else {
            Write-Log "File $destination already exists. Skipping download."
        }
    }
}

Write-Log 'Installing cert-manager' -Console
$certManagerConfig = Get-CertManagerConfig
(Invoke-Kubectl -Params 'apply', '-f', $certManagerConfig).Output | Write-Log

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
(Invoke-Kubectl -Params 'apply', '-f', $caIssuerConfig).Output | Write-Log

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

Write-Log 'Renewing old Certificates using the new CA Issuer' -Console
Update-CertificateResources

Write-Log 'Importing CA root certificate to trusted authorities of your computer' -Console
$b64secret = (Invoke-Kubectl -Params '-n', 'cert-manager', 'get', 'secrets', 'ca-issuer-root-secret', '-o', 'jsonpath', '--template', '{.data.ca\.crt}').Output
$tempFile = New-TemporaryFile
$certLocationStore = Get-TrustedRootStoreLocation
[Text.Encoding]::Utf8.GetString([Convert]::FromBase64String($b64secret)) | Out-File -Encoding ASCII -FilePath $tempFile.FullName -Force
$params = @{
    FilePath          = $tempFile.FullName
    CertStoreLocation = $certLocationStore
}

Import-Certificate @params

Copy-ToControlPlaneViaSSHKey $tempFile.FullName '/tmp/certmgr-ca.crt'
(Invoke-CmdOnControlPlaneViaSSHKey 'sudo mv /tmp/certmgr-ca.crt /etc/kubernetes/pki').Output | Write-Log
Remove-Item -Path $tempFile.FullName -Force

Write-Log 'Checking for availability of Ingress Controller' -Console
if (Test-NginxIngressControllerAvailability) {
    $activeIngress = 'nginx'
}
elseif (Test-TraefikIngressControllerAvailability) {
    $activeIngress = 'traefik'
}
else {
    #Enable required ingress addon
    Write-Log "No Ingress controller found in the cluster, enabling $Ingress controller" -Console
    Enable-IngressAddon -Ingress:$Ingress
    $activeIngress = $Ingress
}

Write-Log 'Installing keycloak' -Console
$keyCloakYaml = Get-KeyCloakConfig
(Invoke-Kubectl -Params 'apply', '-f', $keyCloakYaml).Output | Write-Log
Deploy-IngressForSecurity -Ingress:$activeIngress
Write-Log 'Waiting for keycloak pods to be available' -Console
$keycloakPodStatus = Wait-ForKeyCloakAvailable

$oauth2ProxyYaml = Get-OAuth2ProxyConfig
(Invoke-Kubectl -Params 'apply', '-f', $oauth2ProxyYaml).Output | Write-Log
Write-Log 'Waiting for oauth2-proxy pods to be available' -Console
$oauth2ProxyPodStatus = Wait-ForOauth2ProxyAvailable

if ($keycloakPodStatus -ne $true -or $oauth2ProxyPodStatus -ne $true) {
    $errMsg = "All security pods could not become ready. Please use kubectl describe for more details.`nInstallation of security addon failed."
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Updating kube API server configuration. This might take minutes, be patient!' -Console
$oidcIssuerLine = '    - --oidc-issuer-url=https://k2s.cluster.local/keycloak/realms/demo-app'
$oidcClientLine = '    - --oidc-client-id=demo-client'
$oidcCaFileLine = '    - --oidc-ca-file=/etc/kubernetes/pki/certmgr-ca.crt'
$apiServerFile = '/etc/kubernetes/manifests/kube-apiserver.yaml'
$insertionPoint = '^\s*image:'

$sedCommand = "sudo sed '/$insertionPoint/i\$oidcIssuerLine\n$oidcClientLine\n$oidcCaFileLine' $apiServerFile > /tmp/kube-apiserver.yaml"
(Invoke-CmdOnControlPlaneViaSSHKey $sedCommand).Output | Write-Log
(Invoke-CmdOnControlPlaneViaSSHKey "sudo mv /tmp/kube-apiserver.yaml $apiServerFile").Output | Write-Log

$keycloakPodStatus = Wait-ForKeyCloakAvailable
if ($keycloakPodStatus -ne $true) {
    $errMsg = 'Could not restart after reconfiguration of kube api server. System is in inconsistent state.'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

# if security addon is enabled, than adapt other addons
Update-Addons

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'security' })

Write-Log 'Installation of security finished.' -Console

Write-SecurityUsageForUser
Write-SecurityWarningForUser

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
