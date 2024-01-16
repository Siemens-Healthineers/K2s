# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$configModule = "$PSScriptRoot\..\..\..\..\..\k2s.infra.module\config\config.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\..\..\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\..\..\k2s.infra.module\log\log.module.psm1"
$systemModule = "$PSScriptRoot\..\..\..\system\system.module.psm1"
Import-Module $logModule, $configModule, $pathModule, $systemModule

$kubeBinPath = Get-KubeBinPath
# Putty tools
$windowsNode_PuttytoolsDirectory = "puttytools"

function Invoke-DownloadPuttyArtifacts($downloadsBaseDirectory, $Proxy) {
    $puttytoolsDownloadsDirectory = "$downloadsBaseDirectory\$windowsNode_PuttytoolsDirectory"
    $windowsNode_Plink = "plink.exe"
    $windowsNode_Pscp = "pscp.exe"
    Write-Log "Create folder '$puttytoolsDownloadsDirectory'"
    mkdir $puttytoolsDownloadsDirectory | Out-Null

    Write-Log "Download plink"
    Invoke-DownloadFile "$puttytoolsDownloadsDirectory\$windowsNode_Plink" https://the.earth.li/~sgtatham/putty/0.76/w64/$windowsNode_Plink $true $Proxy
    Write-Log "Download pscp"
    Invoke-DownloadFile "$puttytoolsDownloadsDirectory\$windowsNode_Pscp" https://the.earth.li/~sgtatham/putty/0.76/w64//$windowsNode_Pscp $true $Proxy
}

function Invoke-DeployPuttytoolsArtifacts($windowsNodeArtifactsDirectory) {
    $puttytoolsArtifactsDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_PuttytoolsDirectory"
    if (!(Test-Path "$puttytoolsArtifactsDirectory")) {
        throw "Directory '$puttytoolsArtifactsDirectory' does not exist"
    }
    Write-Log "Publish plink"
    Copy-Item -Path "$puttytoolsArtifactsDirectory\$windowsNode_Plink" -Destination "$kubeBinPath" -Force
    Write-Log "Publish pscp"
    Copy-Item -Path "$puttytoolsArtifactsDirectory\$windowsNode_Pscp" -Destination "$kubeBinPath" -Force
}

