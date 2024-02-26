# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
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
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1
. $PSScriptRoot\Common.ps1

$logModule = "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
$statusModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/status/status.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$cliMessagesModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/cli-messages/cli-messages.module.psm1"

Import-Module $logModule, $addonsModule, $statusModule, $cliMessagesModule

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

if ((Test-IsAddonEnabled -Name 'traefik') -eq $true) {
    $errMsg = "Addon 'traefik' is already enabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = @{Type = 'precondition-not-met'; Code = 'addon-already-enabled'; Message = $errMsg } }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

if ((Test-IsAddonEnabled -Name 'ingress-nginx') -eq $true) {
    $errMsg = "Addon 'ingress-nginx' is enabled. Disable it first to avoid port conflicts."

    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = @{Type = 'precondition-not-met'; Code = 'addon-already-enabled'; Message = $errMsg } }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

if ((Test-IsAddonEnabled -Name 'gateway-nginx') -eq $true) {
    $errMsg = "Addon 'gateway-nginx' is enabled. Disable it first to avoid port conflicts."

    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = @{Type = 'precondition-not-met'; Code = 'addon-already-enabled'; Message = $errMsg } }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Installing Traefik Ingress controller' -Console
$traefikYamlDir = Get-TraefikYamlDir
&$global:KubectlExe create namespace traefik | Write-Log
&$global:KubectlExe apply -k "$traefikYamlDir" | Write-Log
$allPodsAreUp = Wait-ForPodsReady -Selector 'app.kubernetes.io/name=traefik' -Namespace 'traefik'

Write-Log "Setting $global:IP_Master as an external IP for traefik service" -Console
$patchJson = ''
if ($PSVersionTable.PSVersion.Major -gt 5) {
    $patchJson = '{"spec":{"externalIPs":["' + $global:IP_Master + '"]}}'
}
else {
    $patchJson = '{\"spec\":{\"externalIPs\":[\"' + $global:IP_Master + '\"]}}'
}
&$global:KubectlExe patch svc traefik -p "$patchJson" -n traefik | Write-Log

if ($allPodsAreUp -ne $true) {
    $errMsg = "All traefik pods could not become ready. Please use kubectl describe for more details.`nInstallation of traefik addon failed"
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = @{Message = $errMsg } }
        return
    }

    Write-Log $errMsg -Error
    exit 1 
}

Write-Log 'All traefik pods are up and ready.' -Console

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'traefik' })

Write-Log 'Installation of Traefik addon finished.' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}