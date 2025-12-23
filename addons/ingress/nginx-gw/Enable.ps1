# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs nginx-gw - kubernetes gateway api controller(gateway controller)

.DESCRIPTION
NA

.EXAMPLE
# For k2sSetup.
powershell <installation folder>\addons\ingress\nginx-gw\Enable.ps1
#>

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
$infraModule = "$PSScriptRoot/../../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"
$gatewayModule = "$PSScriptRoot\nginx-gw.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule, $gatewayModule

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

$setupInfo = Get-SetupInfo
if ($setupInfo.Name -ne 'k2s') {
    $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon 'ingress nginx-gw' can only be enabled for 'k2s' setup type."  
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'ingress'; Implementation = 'nginx-gw' })) -eq $true) {
    $errMsg = "Addon 'ingress nginx-gw' is already enabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'ingress'; Implementation = 'nginx' })) -eq $true) {
    $errMsg = "Addon 'ingress nginx' is enabled. Disable it first to avoid port conflicts."

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

# has to be discussed 
# if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'gateway-api' })) -eq $true) {
#     $errMsg = "Addon 'gateway-api' is enabled. Disable it first to avoid port conflicts."

#     if ($EncodeStructuredOutput -eq $true) {
#         $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
#         Send-ToCli -MessageType $MessageType -Message @{Error = $err }
#         return
#     }

#     Write-Log $errMsg -Error
#     exit 1
# }

$existingServices = (Invoke-Kubectl -Params 'get', 'service', '-n', 'nginx-gw', '-o', 'yaml').Output
if ("$existingServices" -match '.*nginx-gw.*') {
    $errMsg = 'It seems as if ingress nginx gateway is already installed in the namespace nginx-gw. Disable it before enabling it again.'
    
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

$kustomization = @"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- ../manifests
"@

#create a temporary directory to store the kustomization file
$kustomizationDir = "$PSScriptRoot/kustomizationDir"
New-Item -Path $kustomizationDir -ItemType 'directory' -ErrorAction SilentlyContinue
$kustomizationFile = "$kustomizationDir\kustomization.yaml"
$kustomization | Out-File $kustomizationFile

Write-Log 'Installing nginx gateway' -Console
$ingressNginxGatewayNamespace = 'nginx-gw'

# Apply NGF CRDs first using server-side apply to avoid oversized
# last-applied annotations on large CRDs
$CrdsDirectory = Get-NginxGatewayCrdsDir
(Invoke-Kubectl -Params 'apply', '--server-side', '-f', $CrdsDirectory).Output | Write-Log

(Invoke-Kubectl -Params 'apply' , '-k', $kustomizationDir).Output | Write-Log

# # delete the temporary directory
Remove-Item -Path $kustomizationDir -Recurse

$controlPlaneIp = Get-ConfiguredIPControlPlane

Write-Log "Setting $controlPlaneIp as an external IP for nginx-gw service" -Console
$patchJson = ''
if ($PSVersionTable.PSVersion.Major -gt 5) {
    $patchJson = '{"spec":{"externalIPs":["' + $controlPlaneIp + '"]}}'
}
else {
    $patchJson = '{\"spec\":{\"externalIPs\":[\"' + $controlPlaneIp + '\"]}}'
}
$ingressNginxGatewaySvc = 'nginx-gw'

(Invoke-Kubectl -Params 'patch', 'svc', $ingressNginxGatewaySvc, '-p', "$patchJson", '-n', $ingressNginxGatewayNamespace).Output | Write-Log

$allPodsAreUp = (Wait-ForPodCondition -Condition Ready -Label 'app.kubernetes.io/component=controller' -Namespace 'nginx-gw' -TimeoutSeconds 300)
# $allJobsAreCompleted = (Wait-ForJobCondition -Condition Complete -Label 'app.kubernetes.io/component=admission-webhook' -Namespace 'nginx-gw' -TimeoutSeconds 300)


 if ($allPodsAreUp -ne $true) {
#  if ($allPodsAreUp -ne $true -or $allJobsAreCompleted -ne $true) {
    $errMsg = "All ingress nginx pods could not become ready. Please use kubectl describe for more details.`nInstallation of ingress nginx failed."
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

$clusterIngressConfig = "$PSScriptRoot\manifests\cluster-local-nginx-gw.yaml"
(Invoke-Kubectl -Params 'apply' , '-f', $clusterIngressConfig).Output | Write-Log

Write-Log 'All nginx gateway pods are up and ready.'

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'ingress'; Implementation = 'nginx-gw' })

&"$PSScriptRoot\Update.ps1"

# adapt other addons
Update-Addons -AddonName $addonName

Write-Log 'nginx-gw installed successfully' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}