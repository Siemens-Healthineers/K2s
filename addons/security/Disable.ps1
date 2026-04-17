# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
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

$addonEnabled = Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'security' })

Write-Log 'Checking if cert-manager can be uninstalled' -Console
$hasNginxIngress = Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'ingress'; Implementation = 'nginx' })
$hasTraefikIngress = Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'ingress'; Implementation = 'traefik' })
$hasNginxGwIngress = Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'ingress'; Implementation = 'nginx-gw' })

if ($hasNginxIngress -or $hasTraefikIngress -or $hasNginxGwIngress) {
    Write-Log 'cert-manager is required for enabled ingress addons. Skipping cert-manager uninstallation.' -Console
} else {
    Write-Log 'Uninstalling cert-manager' -Console
    Uninstall-CertManager
}

$oauth2ProxyYaml = Get-OAuth2ProxyConfig
(Invoke-Kubectl -Params 'delete', '--ignore-not-found', '-f', $oauth2ProxyYaml).Output | Write-Log

$oauth2ProxyHydraYaml = Get-OAuth2ProxyHydraConfig  
(Invoke-Kubectl -Params 'delete', '--ignore-not-found', '-f', $oauth2ProxyHydraYaml).Output | Write-Log

$keyCloakYaml = Get-KeyCloakConfig
(Invoke-Kubectl -Params 'delete', '--ignore-not-found', '-f',$keyCloakYaml).Output | Write-Log

$keyCloakPostgresYaml = Get-KeyCloakPostgresConfig
(Invoke-Kubectl -Params 'delete', '--ignore-not-found', '-f', $keyCloakPostgresYaml).Output | Write-Log

Remove-WindowsSecurityDeployments

$needsGatewayApiCrds = $hasNginxGwIngress -or $hasTraefikIngress
if ($needsGatewayApiCrds) {
    Write-Log 'Gateway API ingress is enabled. Preserving Gateway API CRDs before Linkerd deletion.' -Console
    $gatewayApiCrds = Get-GatewayApiCrdsConfig
}

$linkerdYaml = Get-LinkerdConfigDirectory
$linkerdCrdsFile = Join-Path $linkerdYaml 'linkerd-crds.yaml'
if (Test-Path $linkerdCrdsFile) {
    (Invoke-Kubectl -Params 'delete', '--ignore-not-found', '-k',$linkerdYaml).Output | Write-Log

    if ($needsGatewayApiCrds) {
        Write-Log 'Re-applying Gateway API CRDs (removed by Linkerd deletion)' -Console
        (Invoke-Kubectl -Params 'apply', '-f', $gatewayApiCrds).Output | Write-Log
    }
} else {
    Write-Log 'Linkerd manifests not found, skipping kustomize deletion' -Console
}

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

Write-Log 'Cleaning up NGINX Gateway OAuth2 auth resources' -Console
Write-Log '  Deleting oauth2-auth-filter SnippetsFilters...' -Console
$snippetsFilterCrd = (Invoke-Kubectl -Params 'api-resources', '--api-group=gateway.nginx.org', '-o', 'name', '--no-headers').Output 2>$null
if ($snippetsFilterCrd -and $snippetsFilterCrd -match 'snippetsfilters') {
    (Invoke-Kubectl -Params 'delete', 'snippetsfilter', 'oauth2-auth-filter', '-A', '--ignore-not-found').Output | Write-Log
} else {
    Write-Log '  SnippetsFilter CRD not found, skipping' -Console
}

Write-Log '  Deleting oauth2-proxy-config ConfigMap...' -Console
(Invoke-Kubectl -Params 'delete', 'configmap', 'oauth2-proxy-config', '-n', 'security', '--ignore-not-found').Output | Write-Log

Write-Log 'Reverting NGINX Gateway controller configuration' -Console
$deployment = kubectl get deployment nginx-gw-controller -n nginx-gw -o json 2>$null | ConvertFrom-Json
if ($deployment) {
    $args = $deployment.spec.template.spec.containers[0].args
    $flagIndex = $args.IndexOf('--snippets-filters')
    
    if ($flagIndex -ge 0) {
        Write-Log '  Removing --snippets-filters flag from controller...' -Console
        $deploymentPatchFile = [System.IO.Path]::GetTempFileName()
        $deploymentPatch = "[{`"op`":`"remove`",`"path`":`"/spec/template/spec/containers/0/args/$flagIndex`"}]"
        Set-Content -Path $deploymentPatchFile -Value $deploymentPatch -NoNewline
        kubectl patch deployment nginx-gw-controller -n nginx-gw --type=json --patch-file $deploymentPatchFile 2>&1 | Write-Log
        Remove-Item -Path $deploymentPatchFile -Force
    }
}
$clusterRole = kubectl get clusterrole nginx-gw -o json 2>$null | ConvertFrom-Json
if ($clusterRole) {
    $ruleIndex = -1
    for ($i = 0; $i -lt $clusterRole.rules.Count; $i++) {
        $rule = $clusterRole.rules[$i]
        if ($rule.apiGroups -contains 'gateway.nginx.org' -and $rule.resources -contains 'snippetsfilters') {
            $ruleIndex = $i
            break
        }
    }
    if ($ruleIndex -ge 0) {
        Write-Log '  Removing snippetsfilters RBAC permissions...' -Console
        $clusterRolePatchFile = [System.IO.Path]::GetTempFileName()
        $clusterRolePatch = "[{`"op`":`"remove`",`"path`":`"/rules/$ruleIndex`"}]"
        Set-Content -Path $clusterRolePatchFile -Value $clusterRolePatch -NoNewline
        kubectl patch clusterrole nginx-gw --type=json --patch-file $clusterRolePatchFile 2>&1 | Write-Log
        Remove-Item -Path $clusterRolePatchFile -Force
        Write-Log '  Restarting controller pod...' -Console
        kubectl delete pod -l app.kubernetes.io/name=nginx-gateway -n nginx-gw 2>&1 | Write-Log
    }
}

if ($addonEnabled) {
    Remove-AddonFromSetupJson -Addon ([pscustomobject] @{Name = 'security' })
}

# if security addon is enabled, than adapt other addons
# Important is that update is called at the end because addons check state of security addon
Update-Addons -AddonName $addonName

Write-Log 'Uninstallation of security finished' -Console

Write-SecurityWarningForUser

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}