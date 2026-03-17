# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$configModule = "$PSScriptRoot\..\..\..\..\..\k2s.infra.module\config\config.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\..\..\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\..\..\k2s.infra.module\log\log.module.psm1"
$systemModule = "$PSScriptRoot\..\..\..\system\system.module.psm1"
$networkModule = "$PSScriptRoot\..\..\..\network\loopbackadapter.module.psm1"
Import-Module $logModule, $configModule, $pathModule, $systemModule, $networkModule

$kubeBinPath = Get-KubeBinPath

$httpProxyPort = '8181'
$proxyInboundFirewallRule = "HTTP Proxy Inbound Allow Port $httpProxyPort"

function Install-WinHttpProxy {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Proxy for Host')]
        [string]$Proxy = '',
        [parameter(Mandatory = $false, HelpMessage = 'No Proxy for Host')]
        [string[]]$ProxyOverrides = @()
    )


    mkdir -Force "$(Get-SystemDriveLetter):\var\log\httpproxy" | Out-Null
    &$kubeBinPath\nssm install httpproxy "$kubeBinPath\httpproxy.exe"
    &$kubeBinPath\nssm set httpproxy AppDirectory $kubeBinPath | Out-Null

    Set-ProxyConfigInHttpProxy -Proxy:$Proxy -ProxyOverrides:$ProxyOverrides

    &$kubeBinPath\nssm set httpproxy AppStdout "$(Get-SystemDriveLetter):\var\log\httpproxy\httpproxy_stdout.log" | Out-Null
    &$kubeBinPath\nssm set httpproxy AppStderr "$(Get-SystemDriveLetter):\var\log\httpproxy\httpproxy_stderr.log" | Out-Null
    &$kubeBinPath\nssm set httpproxy AppStdoutCreationDisposition 4 | Out-Null
    &$kubeBinPath\nssm set httpproxy AppStderrCreationDisposition 4 | Out-Null
    &$kubeBinPath\nssm set httpproxy AppRotateFiles 1 | Out-Null
    &$kubeBinPath\nssm set httpproxy AppRotateOnline 1 | Out-Null
    &$kubeBinPath\nssm set httpproxy AppRotateSeconds 0 | Out-Null
    &$kubeBinPath\nssm set httpproxy AppRotateBytes 500000 | Out-Null
    &$kubeBinPath\nssm set httpproxy Start SERVICE_AUTO_START | Out-Null

    # Give the console control handler enough time to run Stop-System.ps1 during
    # Windows shutdown. NSSM default is ~1.5s per method which is too short for
    # HNS cleanup. 30s for the console method covers all shutdown operations;
    # window and thread methods are skipped (not applicable for a console app).
    &$kubeBinPath\nssm set httpproxy AppStopMethodConsole 30000 | Out-Null
    &$kubeBinPath\nssm set httpproxy AppStopMethodWindow 0 | Out-Null
    &$kubeBinPath\nssm set httpproxy AppStopMethodThreads 0 | Out-Null

    New-NetFirewallRule -DisplayName $proxyInboundFirewallRule -Group 'k2s' -Direction Inbound -LocalPort 8181 -Protocol TCP -Action Allow | Out-Null
    Start-Service httpproxy
}

function Start-WinHttpProxy {
    param (
    [Parameter(Mandatory = $false)]
    [switch]$OnlyProxy = $false
    )
    # Ensure NSSM stop-method timeouts are configured. This is self-healing for
    # installations that were created before these settings were added to
    # Install-WinHttpProxy, so existing systems also get the fix on next start.
    if (Test-Path "$kubeBinPath\nssm.exe") {
        &$kubeBinPath\nssm set httpproxy AppStopMethodConsole 30000 2>&1 | Out-Null
        &$kubeBinPath\nssm set httpproxy AppStopMethodWindow 0 2>&1 | Out-Null
        &$kubeBinPath\nssm set httpproxy AppStopMethodThreads 0 2>&1 | Out-Null
    }
    Start-ServiceAndSetToAutoStart -Name 'httpproxy'
    if ($OnlyProxy) { return }
    Confirm-LoopbackAdapterIP
    # Flanneld must remain SERVICE_DEMAND_START to prevent cbr0 L2Bridge race condition.
    Start-Service 'flanneld' -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    Write-Log "Service 'flanneld' started"
}

function Stop-WinHttpProxy {
    Stop-ServiceAndSetToManualStart 'flanneld'
    Stop-ServiceAndSetToManualStart 'httpproxy'
}

function Remove-WinHttpProxy {
    Remove-ServiceIfExists 'httpproxy'
    $rule = Get-NetFirewallRule -DisplayName $proxyInboundFirewallRule -ErrorAction SilentlyContinue
    if ($null -ne $rule) {
        Remove-NetFirewallRule -DisplayName $proxyInboundFirewallRule
    }
}

function Set-ProxyConfigInHttpProxy {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Proxy for Host')]
        [string]$Proxy = '',
        [parameter(Mandatory = $false, HelpMessage = 'No Proxy for Host')]
        [string[]]$ProxyOverrides = @()
    )
    $ipControlPlaneCIDR = Get-ConfiguredControlPlaneCIDR
    $clusterCIDR = Get-ConfiguredClusterCIDR
    $clusterCIDRServices = Get-ConfiguredClusterCIDRServices
    $loopbackAdapterCIDR = Get-LoopbackAdapterCIDR

    $appParameters = "--allowed-cidr $clusterCIDR --allowed-cidr $clusterCIDRServices --allowed-cidr $ipControlPlaneCIDR --allowed-cidr $loopbackAdapterCIDR"
    if ( $Proxy -ne '' ) {
        $appParameters = $appParameters + " --forwardproxy $Proxy"
    }
    
    $k2sHosts = Get-K2sHosts
    
    $allNoProxyHosts = @()
    if ($ProxyOverrides.Count -gt 0) {
        $allNoProxyHosts += $ProxyOverrides
    }
    $allNoProxyHosts += $k2sHosts
    
    $uniqueNoProxyHosts = $allNoProxyHosts | Sort-Object -Unique
    
    if ($uniqueNoProxyHosts.Count -gt 0) {
        $noProxyValue = $uniqueNoProxyHosts -join ','
        &$kubeBinPath\nssm set httpproxy AppEnvironmentExtra "NO_PROXY=$noProxyValue" | Out-Null
        Write-Log "HTTP Proxy service configured with NO_PROXY: $noProxyValue"
    } else {
        &$kubeBinPath\nssm set httpproxy AppEnvironmentExtra "NO_PROXY=.local" | Out-Null
        Write-Log "HTTP Proxy service configured with default NO_PROXY: .local"
    }
        
    &$kubeBinPath\nssm set httpproxy AppParameters $appParameters | Out-Null
    
    if ( $Proxy -ne '' ) {
        Write-Log "HTTP Proxy service configured with forward proxy: $Proxy"
    }
}
