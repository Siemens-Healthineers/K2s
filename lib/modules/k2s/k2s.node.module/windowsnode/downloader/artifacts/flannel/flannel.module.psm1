# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$configModule = "$PSScriptRoot\..\..\..\..\..\k2s.infra.module\config\config.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\..\..\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\..\..\k2s.infra.module\log\log.module.psm1"
$systemModule = "$PSScriptRoot\..\..\..\system\system.module.psm1"
$networkModule = "$PSScriptRoot\..\..\..\network\loopbackadapter.module.psm1"
Import-Module $logModule, $configModule, $pathModule, $systemModule, $networkModule

$kubePath = Get-KubePath
$kubeBinPath = Get-KubeBinPath
$cniPath = "$kubePath\bin\cni"


# flannel
$windowsNode_FlannelDirectory = 'flannel'
$windowsNode_CniPluginsDirectory = 'cni_plugins'
$windowsNode_CniFlannelDirectory = 'cni_flannel'

$windowsNode_FlanneldExe = 'flanneld.exe'
$windowsNode_Flannel64exe = 'flannel-amd64.exe'

function Invoke-DownloadFlannelArtifacts($downloadsBaseDirectory, $Proxy) {
    $flannelDownloadsDirectory = "$downloadsBaseDirectory\$windowsNode_FlannelDirectory"
    $flannelVersion = 'v0.28.0'
    $file = "$flannelDownloadsDirectory\$windowsNode_FlanneldExe"

    Write-Log "Create folder '$flannelDownloadsDirectory'"
    mkdir $flannelDownloadsDirectory | Out-Null
    Write-Log 'Download flannel'
    Invoke-DownloadFile "$file" https://github.com/coreos/flannel/releases/download/$flannelVersion/$windowsNode_FlanneldExe $true $Proxy
}

function Invoke-DownloadCniPlugins($downloadsBaseDirectory, $Proxy) {
    $cniPluginsDownloadsDirectory = "$downloadsBaseDirectory\$windowsNode_CniPluginsDirectory"
    $cniPluginVersion = 'v1.9.0'
    $cniPlugins = "cni-plugins-windows-amd64-$cniPluginVersion.tgz"
    $compressedFile = "$cniPluginsDownloadsDirectory\$cniPlugins"

    Write-Log "Create folder '$cniPluginsDownloadsDirectory'"
    mkdir $cniPluginsDownloadsDirectory | Out-Null
    Write-Log 'Download cni plugins'
    Invoke-DownloadFile "$compressedFile" https://github.com/containernetworking/plugins/releases/download/$cniPluginVersion/$cniPlugins $true $Proxy
    Write-Log '  ...done'
    Write-Log "Extract downloaded file '$compressedFile'"
    $ErrorActionPreference = 'Continue'
    tar.exe xvf `"$compressedFile`" -C `"$cniPluginsDownloadsDirectory`" 2>&1 | % { "$_" }
    $ErrorActionPreference = 'Stop'
    Write-Log '  ...done'
    Remove-Item -Path "$compressedFile" -Force -ErrorAction SilentlyContinue
}

function Invoke-DownloadCniFlannelArtifacts($downloadsBaseDirectory, $Proxy) {
    $cniFlannelDownloadsDirectory = "$downloadsBaseDirectory\$windowsNode_CniFlannelDirectory"
    $cniFlannelVersion = 'v1.0.1'
    $file = "$cniFlannelDownloadsDirectory\$windowsNode_Flannel64exe"

    Write-Log "Create folder '$cniFlannelDownloadsDirectory'"
    mkdir $cniFlannelDownloadsDirectory | Out-Null
    Write-Log 'Download cni flannel'
    Invoke-DownloadFile "$file" https://github.com/flannel-io/cni-plugin/releases/download/$cniFlannelVersion/$windowsNode_Flannel64exe $true $Proxy
    Write-Log '  ...done'
}

function Invoke-DeployFlannelArtifacts($windowsNodeArtifactsDirectory) {
    $flannelArtifactsDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_FlannelDirectory"
    if (!(Test-Path "$flannelArtifactsDirectory")) {
        throw "Directory '$flannelArtifactsDirectory' does not exist"
    }
    Write-Log 'Publish flannel artifacts'
    Copy-Item -Path "$flannelArtifactsDirectory\$windowsNode_FlanneldExe" -Destination "$kubeBinPath\cni" -Force
}

function Invoke-DeployCniPlugins($windowsNodeArtifactsDirectory) {
    $cniPluginsArtifactsDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_CniPluginsDirectory"
    if (!(Test-Path "$cniPluginsArtifactsDirectory")) {
        throw "Directory '$cniPluginsArtifactsDirectory' does not exist"
    }
    Write-Log 'Publish cni plugins artifacts'
    Copy-Item -Path "$cniPluginsArtifactsDirectory\*.*" -Destination "$cniPath" -Force
}

function Invoke-DeployCniFlannelArtifacts($windowsNodeArtifactsDirectory) {
    $cniFlannelArtifactsDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_CniFlannelDirectory"
    if (!(Test-Path "$cniFlannelArtifactsDirectory")) {
        throw "Directory '$cniFlannelArtifactsDirectory' does not exist"
    }
    Write-Log 'Publish cni flannel artifacts'
    Copy-Item "$cniFlannelArtifactsDirectory\$windowsNode_Flannel64exe" "$cniPath\flannel.exe" -Force
}

function Install-WinFlannel {
    Write-Log 'Registering flanneld service'
    mkdir -Force "$(Get-SystemDriveLetter):\var\log\flanneld" | Out-Null
    &$kubeBinPath\nssm install flanneld "$kubeBinPath\cni\flanneld.exe"
    $adapterName = Get-L2BridgeName
    Write-Log "Using network adapter '$adapterName'"
    $ipaddresses = @(Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias "*$adapterName*")
    if (!$ipaddresses) {
        throw 'No IP address found which can be used for setting up K2s Setup !'
    }

    $ipaddress = $ipaddresses[0] | Select-Object -ExpandProperty IPAddress
    if (!($ipaddress)) {
        $ipaddress = Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias "*$adapterName*" | Select-Object -ExpandProperty IPAddress
    }

    Write-Log "Using local IP $ipaddress for AppParameters of flanneld"
    
    $windowsHostIpAddress = Get-ConfiguredKubeSwitchIP
    $httpProxyUrl = "http://$($windowsHostIpAddress):8181"
    
    $k2sHosts = Get-K2sHosts
    $noProxyValue = $k2sHosts -join ','
    
    $hn = ($(hostname)).ToLower()
    # Build environment variables as separate lines for NSSM
    $envVars = "NODE_NAME=$hn`r`nHTTP_PROXY=$httpProxyUrl`r`nHTTPS_PROXY=$httpProxyUrl`r`nNO_PROXY=$noProxyValue"
    &$kubeBinPath\nssm set flanneld AppEnvironmentExtra $envVars | Out-Null
    Write-Log "Flanneld service configured to use HTTP proxy: $httpProxyUrl with NO_PROXY: $noProxyValue"

    &$kubeBinPath\nssm set flanneld AppParameters "--kubeconfig-file=\`"$kubePath\config\`" --iface=$ipaddress --ip-masq=1 --kube-subnet-mgr=1" | Out-Null
    &$kubeBinPath\nssm set flanneld AppDirectory "$(Get-SystemDriveLetter):\" | Out-Null
    &$kubeBinPath\nssm set flanneld AppStdout "$(Get-SystemDriveLetter):\var\log\flanneld\flanneld_stdout.log" | Out-Null
    &$kubeBinPath\nssm set flanneld AppStderr "$(Get-SystemDriveLetter):\var\log\flanneld\flanneld_stderr.log" | Out-Null
    &$kubeBinPath\nssm set flanneld AppStdoutCreationDisposition 4 | Out-Null
    &$kubeBinPath\nssm set flanneld AppStderrCreationDisposition 4 | Out-Null
    &$kubeBinPath\nssm set flanneld AppRotateFiles 1 | Out-Null
    &$kubeBinPath\nssm set flanneld AppRotateOnline 1 | Out-Null
    &$kubeBinPath\nssm set flanneld AppRotateSeconds 0 | Out-Null
    &$kubeBinPath\nssm set flanneld AppRotateBytes 500000 | Out-Null
    &$kubeBinPath\nssm set flanneld Start SERVICE_AUTO_START | Out-Null
    &$kubeBinPath\nssm set flanneld DependOnService httpproxy | Out-Null
}


