# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Enables ingress nginx in the cluster to the ingress-nginx namespace

.DESCRIPTION
Ingress nginx is using k8s load balancer and is bound to the IP of the master machine.
It allows applications to register their ingress resources and handles incoming HTTP/HTPPS traffic.

.EXAMPLE
# For k2sSetup
powershell <installation folder>\addons\ingress\nginx\Enable.ps1
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$infraModule = "$PSScriptRoot/../../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"
$nginxModule = "$PSScriptRoot\nginx.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule, $nginxModule

Initialize-Logging -ShowLogs:$ShowLogs

$windowsHostIpAddress = Get-ConfiguredKubeSwitchIP
$Proxy = "http://$($windowsHostIpAddress):8181"

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

$setupInfo = Get-SetupInfo
if ($setupInfo.Name -ne 'k2s') {
    $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon 'ingress nginx' can only be enabled for 'k2s' setup type."  
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
}

Write-Log 'Checking if ingress nginx is already enabled'

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'ingress'; Implementation = 'nginx' })) -eq $true) {
    $errMsg = "Addon 'ingress nginx' is already enabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'ingress'; Implementation = 'traefik' })) -eq $true) {
    $errMsg = "Addon 'ingress traefik' is enabled. Disable it first to avoid port conflicts."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'gateway-api' })) -eq $true) {
    $errMsg = "Addon 'gateway-api' is enabled. Disable it first to avoid port conflicts."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$existingServices = (Invoke-Kubectl -Params 'get', 'service', '-n', 'ingress-nginx', '-o', 'yaml').Output
if ("$existingServices" -match '.*ingress-nginx-controller.*') {
    $errMsg = 'It seems as if ingress nginx is already installed in the namespace ingress-nginx. Disable it before enabling it again.'
    
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Installing ExternalDNS' -Console
$externalDnsConfig = Get-ExternalDnsConfigDir
(Invoke-Kubectl -Params 'apply' , '-k', $externalDnsConfig).Output | Write-Log

Write-Log 'Installing cert-manager' -Console
Enable-CertManager -Proxy $Proxy -EncodeStructuredOutput:$EncodeStructuredOutput -MessageType:$MessageType

Write-Log 'Installing ingress nginx' -Console
$ingressNginxNamespace = 'ingress-nginx'
$ingressNginxConfig = Get-IngressNginxConfig

(Invoke-Kubectl -Params 'create', 'ns', $ingressNginxNamespace).Output | Write-Log
(Invoke-Kubectl -Params 'apply' , '-f', $ingressNginxConfig).Output | Write-Log

$controlPlaneIp = Get-ConfiguredIPControlPlane

Write-Log "Setting $controlPlaneIp as an external IP for ingress-nginx-controller service" -Console
$patchJson = ''
if ($PSVersionTable.PSVersion.Major -gt 5) {
    $patchJson = '{"spec":{"externalIPs":["' + $controlPlaneIp + '"]}}'
}
else {
    $patchJson = '{\"spec\":{\"externalIPs\":[\"' + $controlPlaneIp + '\"]}}'
}
$ingressNginxSvc = 'ingress-nginx-controller'

(Invoke-Kubectl -Params 'patch', 'svc', $ingressNginxSvc, '-p', "$patchJson", '-n', $ingressNginxNamespace).Output | Write-Log

$allPodsAreUp = (Wait-ForPodCondition -Condition Ready -Label 'app.kubernetes.io/component=controller' -Namespace 'ingress-nginx' -TimeoutSeconds 300)
$allJobsAreCompleted = (Wait-ForJobCondition -Condition Complete -Label 'app.kubernetes.io/component=admission-webhook' -Namespace 'ingress-nginx' -TimeoutSeconds 300)

if ($allPodsAreUp -ne $true -or $allJobsAreCompleted -ne $true) {
    $errMsg = "All ingress nginx pods could not become ready. Please use kubectl describe for more details.`nInstallation of ingress nginx failed."
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$clusterIngressConfig = "$PSScriptRoot\manifests\cluster-local-ingress.yaml"
(Invoke-Kubectl -Params 'apply' , '-f', $clusterIngressConfig).Output | Write-Log



Write-Log 'All ingress nginx pods are up and ready.'

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'ingress'; Implementation = 'nginx' })

Ensure-IngressTlsCertificate -IngressType 'nginx' -CertificateManifestPath $clusterIngressConfig

&"$PSScriptRoot\Update.ps1"

# adapt other addons
Update-Addons -AddonName $addonName

Write-Log 'ingress nginx installed successfully' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}