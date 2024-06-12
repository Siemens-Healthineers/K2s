# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$configModule = "$PSScriptRoot\..\..\..\..\..\k2s.infra.module\config\config.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\..\..\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\..\..\k2s.infra.module\log\log.module.psm1"
$systemModule = "$PSScriptRoot\..\..\..\system\system.module.psm1"
Import-Module $logModule, $configModule, $pathModule, $systemModule

$kubeBinPath = Get-KubeBinPath
$setupConfigRoot = Get-RootConfigk2s
# dns proxy
$windowsNode_DnsProxyDirectory = 'dnsproxy'

function Invoke-DownloadDnsProxyArtifacts($downloadsBaseDirectory) {
    $dnsproxyDownloadsDirectory = "$downloadsBaseDirectory\$windowsNode_DnsProxyDirectory"
    $compressedFile = "$dnsproxyDownloadsDirectory\dnsproxy.zip"

    Write-Log "Create folder '$dnsproxyDownloadsDirectory'"
    mkdir $dnsproxyDownloadsDirectory | Out-Null
    Write-Log 'Download dnsproxy'
    Invoke-DownloadFile "$compressedFile" https://github.com/AdguardTeam/dnsproxy/releases/download/v0.43.1/dnsproxy-windows-amd64-v0.43.1.zip $true
    Write-Log '  ...done'
    Write-Log "Extract downloaded file '$compressedFile'"
    $ErrorActionPreference = 'SilentlyContinue'
    tar C `"$dnsproxyDownloadsDirectory`" -xvf `"$compressedFile`" --strip-components 1 windows-amd64/*.exe 2>&1 | % { "$_" }
    $ErrorActionPreference = 'Stop'
    Write-Log '  ...done'
    Remove-Item -Path "$compressedFile" -Force -ErrorAction SilentlyContinue
}

function Invoke-DeployDnsProxyArtifacts($windowsNodeArtifactsDirectory) {
    $dnsProxyDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_DnsProxyDirectory"
    if (!(Test-Path "$dnsProxyDirectory")) {
        throw "Directory '$dnsProxyDirectory' does not exist"
    }
    Write-Log 'Publish dnsproxy artifacts'
    Copy-Item -Path "$dnsProxyDirectory\*" -Destination "$kubeBinPath" -Recurse -Force
}

function Install-WinDnsProxy {

    Write-Log 'Registering dnsproxy service'
    mkdir -Force "$(Get-SystemDriveLetter):\var\log\dnsproxy" | Out-Null
    &$kubeBinPath\nssm install dnsproxy $kubeBinPath\dnsproxy.exe
    &$kubeBinPath\nssm set dnsproxy AppDirectory $kubeBinPath | Out-Null

    Write-Log 'Creating dnsproxy.yaml (config for dnsproxy.exe)'
    $clusterCIDRNextHop = $setupConfigRoot.psobject.properties['cbr0'].value
    $ipNextHop = $setupConfigRoot.psobject.properties['kubeSwitch'].value
    $ipControlPlane = $setupConfigRoot.psobject.properties['masterIP'].value
    $dnsServer = '8.8.8.8'

    $configContent = @'
# To use it within dnsproxy specify the --config-path=/<path-to-config.yaml>
# option.  Any other command-line options specified will override the values
# from the config file.
---
listen-addrs:
'@

    $configContent += "`n"
    $configContent += "  - ""$clusterCIDRNextHop"" `n"
    $configContent += "  - ""$ipNextHop"" `n"
    $configContent += "upstream: `n"
    $configContent += "  - ""[/local/]$ipControlPlane"" `n"
    $configContent += "  - ""$dnsServer"""

    $configContent | Set-Content "$kubeBinPath\dnsproxy.yaml" -Force

    &$kubeBinPath\nssm set dnsproxy AppParameters " --config-path=\`"$kubeBinPath\dnsproxy.yaml\`" " | Out-Null
    &$kubeBinPath\nssm set dnsproxy AppStdout "$(Get-SystemDriveLetter):\var\log\dnsproxy\dnsproxy_stdout.log" | Out-Null
    &$kubeBinPath\nssm set dnsproxy AppStderr "$(Get-SystemDriveLetter):\var\log\dnsproxy\dnsproxy_stderr.log" | Out-Null
    &$kubeBinPath\nssm set dnsproxy AppStdoutCreationDisposition 4 | Out-Null
    &$kubeBinPath\nssm set dnsproxy AppStderrCreationDisposition 4 | Out-Null
    &$kubeBinPath\nssm set dnsproxy AppRotateFiles 1 | Out-Null
    &$kubeBinPath\nssm set dnsproxy AppRotateOnline 1 | Out-Null
    &$kubeBinPath\nssm set dnsproxy AppRotateSeconds 0 | Out-Null
    &$kubeBinPath\nssm set dnsproxy AppRotateBytes 500000 | Out-Null
    &$kubeBinPath\nssm set dnsproxy Start SERVICE_AUTO_START | Out-Null
}