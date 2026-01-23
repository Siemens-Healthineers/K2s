# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs Traefik Ingress Controller

.DESCRIPTION
NA

.EXAMPLE
# For k2sSetup.
powershell <installation folder>\addons\ingress\traefik\Enable.ps1
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
$traefikModule = "$PSScriptRoot\traefik.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule, $traefikModule

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
    $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon 'ingress traefik' can only be enabled for 'k2s' setup type."  
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'ingress'; Implementation = 'traefik' })) -eq $true) {
    $errMsg = "Addon 'ingress traefik' is already enabled, nothing to do."

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

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'ingress'; Implementation = 'nginx-gw' })) -eq $true) {
    $errMsg = "Addon 'ingress nginx-gw' is enabled. Disable it first to avoid port conflicts."

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

Install-GatewayApiCrds

Write-Log 'Installing external-dns' -Console
$externalDnsConfig = Get-ExternalDnsConfigDir
(Invoke-Kubectl -Params 'apply' , '-k', $externalDnsConfig).Output | Write-Log

Write-Log 'Installing cert-manager' -Console
Enable-CertManager -Proxy $Proxy -EncodeStructuredOutput:$EncodeStructuredOutput -MessageType:$MessageType

# we prepare all patches and apply them in a single kustomization,
# instead of applying the unpatched manifests and then applying patches one by one
$controlPlaneIp = Get-ConfiguredIPControlPlane
Write-Log "Preparing kustomization with $controlPlaneIp as an external IP for traefik service" -Console
$kustomization = @"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- ../manifests

patches:
- patch: |-
    - op: add
      path: /spec/template/spec/containers/0/args/-
      value: --providers.kubernetesIngress.ingressEndpoint
    - op: add
      path: /spec/template/spec/containers/0/args/-
      value: --providers.kubernetesIngress.ingressEndpoint.ip=$controlPlaneIp
  target:
    kind: Deployment
    name: traefik
    namespace: ingress-traefik
- patch: |-
    - op: replace
      path: /spec/externalIPs
      value: 
        - $controlPlaneIp
  target:
    kind: Service
    name: traefik
    namespace: ingress-traefik
"@

# create a temporary directory to store the kustomization file
$kustomizationDir = "$PSScriptRoot/kustomizationDir"
New-Item -Path $kustomizationDir -ItemType 'directory' -ErrorAction SilentlyContinue
$kustomizationFile = "$kustomizationDir\kustomization.yaml"
$kustomization | Out-File $kustomizationFile

Write-Log 'Installing traefik ingress controller' -Console
(Invoke-Kubectl -Params 'create' , 'namespace', 'ingress-traefik').Output | Write-Log
(Invoke-Kubectl -Params 'apply', '-k', $kustomizationDir).Output | Write-Log

# delete the temporary directory
Remove-Item -Path $kustomizationDir -Recurse

$allPodsAreUp = (Wait-ForPodCondition -Condition Ready -Label 'app.kubernetes.io/name=traefik' -Namespace 'ingress-traefik' -TimeoutSeconds 120)

if ($allPodsAreUp -ne $true) {
    $errMsg = "All traefik pods could not become ready. Please use kubectl describe for more details.`nInstallation of ingress traefik addon failed"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = @{Message = $err } }
        return
    }

    Write-Log $errMsg -Error
    exit 1 
}

Write-Log 'All ingress traefik pods are up and ready.' -Console

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'ingress'; Implementation = 'traefik' })

Assert-IngressTlsCertificate -IngressType 'traefik' -CertificateManifestPath "$PSScriptRoot\manifests\cluster-local-ingress.yaml"

&"$PSScriptRoot\Update.ps1"

# adapt other addons
Update-Addons -AddonName $addonName

Write-Log 'Installation of Traefik addon finished.' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}