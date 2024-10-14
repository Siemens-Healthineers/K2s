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
powershell <installation folder>\addons\traefik\Enable.ps1
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
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$commonModule = "$PSScriptRoot\common.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule, $commonModule

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

$setupInfo = Get-SetupInfo
if ($setupInfo.Name -ne 'k2s') {
    $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon 'traefik' can only be enabled for 'k2s' setup type."  
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
}

if ((Test-IsAddonEnabled -Name 'traefik') -eq $true) {
    $errMsg = "Addon 'traefik' is already enabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

if ((Test-IsAddonEnabled -Name 'ingress-nginx') -eq $true) {
    $errMsg = "Addon 'ingress-nginx' is enabled. Disable it first to avoid port conflicts."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

if ((Test-IsAddonEnabled -Name 'gateway-nginx') -eq $true) {
    $errMsg = "Addon 'gateway-nginx' is enabled. Disable it first to avoid port conflicts."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Installing Traefik Ingress controller' -Console
$traefikYamlDir = Get-TraefikYamlDir

(Invoke-Kubectl -Params 'create' , 'namespace', 'traefik').Output | Write-Log
(Invoke-Kubectl -Params 'apply', '-k', $traefikYamlDir).Output | Write-Log

$allPodsAreUp = (Wait-ForPodCondition -Condition Ready -Label 'app.kubernetes.io/name=traefik' -Namespace 'traefik' -TimeoutSeconds 120)

$controlPlaneIp = Get-ConfiguredIPControlPlane

Write-Log "Setting $controlPlaneIp as an external IP for traefik service" -Console
$patchJson = ''
if ($PSVersionTable.PSVersion.Major -gt 5) {
    $patchJson = '{"spec":{"externalIPs":["' + $controlPlaneIp + '"]}}'
}
else {
    $patchJson = '{\"spec\":{\"externalIPs\":[\"' + $controlPlaneIp + '\"]}}'
}
(Invoke-Kubectl -Params 'patch', 'svc', 'traefik', '-p', "$patchJson", '-n', 'traefik').Output | Write-Log

if ($allPodsAreUp -ne $true) {
    $errMsg = "All traefik pods could not become ready. Please use kubectl describe for more details.`nInstallation of traefik addon failed"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = @{Message = $err } }
        return
    }

    Write-Log $errMsg -Error
    exit 1 
}

Write-Log 'All traefik pods are up and ready.' -Console

$clusterIngressConfig = "$PSScriptRoot\manifests\cluster-net-ingress.yaml"
(Invoke-Kubectl -Params 'apply' , '-f', $clusterIngressConfig).Output | Write-Log

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'traefik' })

Write-Log 'Installation of Traefik addon finished.' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}