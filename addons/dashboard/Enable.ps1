# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs Headlamp - Kubernetes Dashboard UI

.EXAMPLE
k2s addons enable dashboard
k2s addons enable dashboard --ingress nginx --enable-metrics
#>

[CmdletBinding(SupportsShouldProcess = $true)]
Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Enable ingress addon')]
    [ValidateSet('nginx', 'nginx-gw', 'traefik', 'none')]
    [string] $Ingress = 'none',
    [parameter(Mandatory = $false, HelpMessage = 'Enable metrics addon')]
    [switch] $EnableMetricsServer = $false,
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
$dashboardModule = "$PSScriptRoot\dashboard.module.psm1"

Import-Module $clusterModule, $infraModule, $addonsModule, $dashboardModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log '[Dashboard] Checking cluster status' -Console

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
    $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon 'dashboard' can only be enabled for 'k2s' setup type."
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'dashboard' })) -eq $true) {
    $errMsg = "Addon 'dashboard' is already enabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

if ($Ingress -ne 'none') {
    Enable-IngressAddon -Ingress:$Ingress
}

if ($EnableMetricsServer) {
    Enable-MetricsServer
}

# Enabling ingress can run nested scripts that force-reload dashboard.module in a
# child scope; ensure dashboard commands are present in the current scope.
if (-not (Get-Command Install-HeadlampViaHelm -ErrorAction SilentlyContinue)) {
    Write-Log '[Dashboard] Re-importing dashboard module after nested addon execution' -Console
    Import-Module $dashboardModule -Force
}

Write-Log '[Dashboard] Installing Headlamp via Helm' -Console

try {
    Install-HeadlampViaHelm
}
catch {
    $errMsg = "Failed to install Headlamp via Helm: $($_.Exception.Message)"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

Write-Log '[Dashboard] Checking Headlamp status' -Console
$headlampReady = Wait-ForHeadlampAvailable
if ($headlampReady -ne $true) {
    $errMsg = "Headlamp pod could not become ready. Please use kubectl describe for more details.`nInstallation of Headlamp dashboard failed."
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}


&"$PSScriptRoot\Update.ps1" -PreferredIngress $(if ($Ingress -eq 'none') { 'auto' } else { $Ingress })

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'dashboard' })

Write-Log '[Dashboard] Syncing Headlamp plugins' -Console
Sync-HeadlampPlugins

Write-HeadlampUsageForUser
Write-BrowserWarningForUser

Write-Log '[Dashboard] Installation of Headlamp dashboard finished.' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}