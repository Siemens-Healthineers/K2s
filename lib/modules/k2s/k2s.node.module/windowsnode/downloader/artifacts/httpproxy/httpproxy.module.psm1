# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$configModule = "$PSScriptRoot\..\..\..\..\..\k2s.infra.module\config\config.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\..\..\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\..\..\k2s.infra.module\log\log.module.psm1"
$systemModule = "$PSScriptRoot\..\..\..\system\system.module.psm1"
$networkModule = "$PSScriptRoot\..\..\..\network\loopbackadapter.module.psm1"
$proxy = "$PSScriptRoot\..\..\..\proxy\proxy.module.psm1"
Import-Module $logModule, $configModule, $pathModule, $systemModule, $networkModule, $proxy

$kubeBinPath = Get-KubeBinPath

function Install-WinHttpProxy {
    # Get user proxy settings
    $proxyConf = Get-ProxySettings

    mkdir -Force "$(Get-SystemDriveLetter):\var\log\httpproxy" | Out-Null
    &$kubeBinPath\nssm install httpproxy "$kubeBinPath\httpproxy.exe"
    &$kubeBinPath\nssm set httpproxy AppDirectory $kubeBinPath | Out-Null

    $ipControlPlaneCIDR = Get-ConfiguredControlPlaneCIDR
    $clusterCIDR = Get-ConfiguredClusterCIDR
    $clusterCIDRServices = Get-ConfiguredClusterCIDRServices
    $loopbackAdapterCIDR = Get-LoopbackAdapterCIDR

    $appParameters = "--allowed-cidr $clusterCIDR --allowed-cidr $clusterCIDRServices --allowed-cidr $ipControlPlaneCIDR --allowed-cidr $loopbackAdapterCIDR --allowed-cidr 127.0.0.0/24"
    if (($null -ne $proxyConf) -and ($proxyConf.HttpProxy -ne '')) {
        $appParameters = $appParameters + " --forwardproxy $($proxyConf.HttpProxy)"
    }
    &$kubeBinPath\nssm set httpproxy AppParameters $appParameters | Out-Null
    &$kubeBinPath\nssm set httpproxy AppStdout "$(Get-SystemDriveLetter):\var\log\httpproxy\httpproxy_stdout.log" | Out-Null
    &$kubeBinPath\nssm set httpproxy AppStderr "$(Get-SystemDriveLetter):\var\log\httpproxy\httpproxy_stderr.log" | Out-Null
    &$kubeBinPath\nssm set httpproxy AppStdoutCreationDisposition 4 | Out-Null
    &$kubeBinPath\nssm set httpproxy AppStderrCreationDisposition 4 | Out-Null
    &$kubeBinPath\nssm set httpproxy AppRotateFiles 1 | Out-Null
    &$kubeBinPath\nssm set httpproxy AppRotateOnline 1 | Out-Null
    &$kubeBinPath\nssm set httpproxy AppRotateSeconds 0 | Out-Null
    &$kubeBinPath\nssm set httpproxy AppRotateBytes 500000 | Out-Null

    if (($null -ne $proxyConf) -and ($proxyConf.NoProxy -ne '')) {
        &$kubeBinPath\nssm set httpproxy AppEnvironmentExtra NO_PROXY=$($proxyConf.NoProxy)
    }

    &$kubeBinPath\nssm set httpproxy Start SERVICE_AUTO_START | Out-Null

    $httpProxyPort = Get-HttpProxyServicePort
    $proxyInboundFirewallRule = "HTTP Proxy Inbound Allow Port $httpProxyPort"

    New-NetFirewallRule -DisplayName $proxyInboundFirewallRule -Group 'k2s' -Direction Inbound -LocalPort $httpProxyPort -Protocol TCP -Action Allow | Out-Null
    Start-Service httpproxy
}

