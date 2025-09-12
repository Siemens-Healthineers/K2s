# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$configModule = "$PSScriptRoot\..\..\..\..\..\k2s.infra.module\config\config.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\..\..\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\..\..\k2s.infra.module\log\log.module.psm1"
$systemModule = "$PSScriptRoot\..\..\..\system\system.module.psm1"
Import-Module $logModule, $configModule, $pathModule, $systemModule

$kubeBinPath = Get-KubeBinPath
# yaml
$windowsNode_YamlDirectory = "yaml"

function Invoke-DownloadYamlArtifacts($downloadsBaseDirectory, $Proxy, $windowsNodeArtifactsDirectory) {
    $yamlDownloadsDirectory = "$downloadsBaseDirectory\$windowsNode_YamlDirectory"
    Write-Log "Create folder '$yamlDownloadsDirectory'"
    mkdir $yamlDownloadsDirectory -ErrorAction SilentlyContinue | Out-Null
    Write-Log "Download jq executable"

    $downloadedFile1 = "$yamlDownloadsDirectory\jq.exe"
    Invoke-DownloadFile "$downloadedFile1" https://github.com/stedolan/jq/releases/download/jq-1.8.1/jq-win64.exe $true $Proxy
    Move-Item -Path "$downloadedFile1" -Destination $yamlDownloadsDirectory
    Write-Log "Move $downloadedFile1 to $yamlDownloadsDirectory done"

    $downloadedFile2 = "$yamlDownloadsDirectory\yq.exe"
    Write-Log "Download yq executable"
    Invoke-DownloadFile "$downloadedFile2" https://github.com/mikefarah/yq/releases/download/v4.47.1/yq_windows_amd64.exe $true $Proxy
    Move-Item -Path "$downloadedFile2" -Destination $yamlDownloadsDirectory
    Write-Log "Move $downloadedFile2 to $yamlDownloadsDirectory done"

    $yamlArtifactsDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_YamlDirectory"

    if (Test-Path("$yamlArtifactsDirectory")) {
        Remove-Item -Path "$yamlArtifactsDirectory" -Force -Recurse
    }

    Copy-Item -Path "$yamlDownloadsDirectory" -Destination "$windowsNodeArtifactsDirectory" -Recurse -Force
}

function Invoke-DeployYamlArtifacts($windowsNodeArtifactsDirectory) {
    $yamlDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_YamlDirectory"
    if (!(Test-Path "$yamlDirectory")) {
        throw "Directory '$yamlDirectory' does not exist"
    }
    Write-Log "Publish yaml artifacts"
    Copy-Item -Path "$yamlDirectory\*" -Destination "$kubeBinPath" -Recurse -Force
}