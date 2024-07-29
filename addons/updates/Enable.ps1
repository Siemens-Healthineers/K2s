# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS

.DESCRIPTION

.EXAMPLE
Enable updates in k2s
powershell <installation folder>\addons\update\Enable.ps1

Enable Dashboard in k2s with ingress-nginx addon and metrics server addon
powershell <installation folder>\addons\update\Enable.ps1 -Ingress "ingress-nginx"
#>

[CmdletBinding(SupportsShouldProcess = $true)]
Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Enable Ingress-Nginx Addon')]
    [ValidateSet('nginx', 'traefik', 'none')]
    [string] $Ingress = 'none',
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$nodeModule = "$PSScriptRoot/../../lib\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$updatesModule = "$PSScriptRoot\updates.module.psm1"

Import-Module $clusterModule, $infraModule, $addonsModule, $nodeModule, $updatesModule

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
    $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon 'updates' can only be enabled for 'k2s' setup type."  
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
}

if ((Test-IsAddonEnabled -Name 'updates') -eq $true) {
    $errMsg = "Addon 'updates' is already enabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

$UpdatesNamespace = 'updates'

$VERSION_ARGOCD = 'v2.9.18'

Write-Log 'Creating updates namespace' -Console
(Invoke-Kubectl -Params 'create', 'namespace', $UpdatesNamespace)

Write-Log 'Installing Updates addon' -Console
$UpdatesConfig = Get-UpdatesConfig
(Invoke-Kubectl -Params 'apply' , '-n', $UpdatesNamespace, '-f', $UpdatesConfig).Output | Write-Log

$binPath = Get-KubeBinPath
if (!(Test-Path "$binPath\argocd.exe")) {
    Write-Log "Downloading ArgoCD binary with version $VERSION_ARGOCD"
    Invoke-DownloadFile "$binPath\argocd.exe" "https://github.com/argoproj/argo-cd/releases/download/$VERSION_ARGOCD/argocd-windows-amd64.exe" $true -ProxyToUse $Proxy
}

Write-Log 'Waiting for pods being ready...' -Console

$kubectlCmd = (Invoke-Kubectl -Params 'rollout', 'status', 'deployments', '-n', $UpdatesNamespace, '--timeout=300s')
Write-Log $kubectlCmd.Output
if (!$kubectlCmd.Success) {
    $errMsg = 'Updates addon could not be deployed successfully!'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$kubectlCmd = (Invoke-Kubectl -Params 'rollout', 'status', 'statefulsets', '-n', $UpdatesNamespace, '--timeout=300s')
Write-Log $kubectlCmd.Output
if (!$kubectlCmd.Success) {
    $errMsg = 'Updates addon (ArgoCD application controller) could not be deployed successfully'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

if ($Ingress -ne 'none') {
    Enable-IngressAddon -Ingress:$Ingress
}

Enable-ExternalAccessIfIngressControllerIsFound

$ArgoCD_Password_output = argocd.exe admin initial-password -n $UpdatesNamespace

$pattern = '^\S+' # Match first squence of non-whitespace characters
$ARGOCD_Password = [regex]::Match($ArgoCD_Password_output, $pattern).Value

$kubectlCmd = (Invoke-Kubectl -Params 'delete', 'secret', 'argocd-initial-secret', '-n', $UpdatesNamespace)
Write-Log $kubectlCmd.Output

Write-Log 'Installation of Kubernetes updates addon finished.' -Console

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'updates' })

Write-UsageForUser $ARGOCD_Password

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}