# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $true, HelpMessage = 'Kubernetes version to use')]
    [string] $KubernetesVersion,
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy = '',
    [parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $SetupType = $(throw 'K8s Setup type required')
)

&$PSScriptRoot\WindowsNodeCommonVariables.ps1
. $PSScriptRoot\..\common\GlobalFunctions.ps1

$ErrorActionPreference = 'Stop'

if (Test-Path($global:WindowsNodeArtifactsDownloadsDirectory)) {
    Write-Log "Remove content of folder '$global:WindowsNodeArtifactsDownloadsDirectory'"
    Remove-Item "$global:WindowsNodeArtifactsDownloadsDirectory\*" -Recurse -Force
} else {
    Write-Log "Create folder '$global:WindowsNodeArtifactsDownloadsDirectory'"
    mkdir $global:WindowsNodeArtifactsDownloadsDirectory | Out-Null
}

Write-Log "Start downloading artifacts for the Windows node"
&$PSScriptRoot\downloader\DownloadNssm.ps1 -Proxy $Proxy -Deploy
&$PSScriptRoot\downloader\DownloadDocker.ps1 -Proxy $Proxy
&$PSScriptRoot\downloader\DownloadContainerd.ps1 -Proxy $Proxy -Deploy
&$PSScriptRoot\downloader\DownloadDnsProxy.ps1 -Proxy $Proxy
&$PSScriptRoot\downloader\DownloadFlannel.ps1 -Proxy $Proxy
&$PSScriptRoot\downloader\DownloadKubetools.ps1 -Proxy $Proxy -KubernetesVersion $KubernetesVersion
&$PSScriptRoot\downloader\DownloadWindowsExporter.ps1 -Proxy $Proxy
&$PSScriptRoot\downloader\DownloadYamlTools.ps1 -Proxy $Proxy -Deploy
&$PSScriptRoot\downloader\DownloadPuttytools.ps1 -Proxy $Proxy

&$PSScriptRoot\publisher\PublishNssm.ps1
&$PSScriptRoot\publisher\PublishContainerd.ps1
&$PSScriptRoot\publisher\PublishYamlTools.ps1

Write-Log "Setup Type: $SetupType, will decide if images need to be downloaded"
if ($SetupType -ne $global:SetupType_MultiVMK8s) {
    Write-Log "Setup Type: $SetupType, download container images"
    &$PSScriptRoot\InstallContainerd.ps1 -Proxy $Proxy
    &$PSScriptRoot\downloader\DownloadWindowsImages.ps1 -Proxy $Proxy
    &$PSScriptRoot\UninstallContainerd.ps1
}
Write-Log "Finished downloading artifacts for the Windows node"

if (Test-Path($global:WindowsNodeArtifactsZipFilePath)) {
    Write-Log "Remove already existing file '$global:WindowsNodeArtifactsZipFilePath'"
    Remove-Item $global:WindowsNodeArtifactsZipFilePath -Force
}

Write-Log "Create compressed file with artifacts for the Windows node"
Compress-Archive -Path "$global:WindowsNodeArtifactsDownloadsDirectory\*" -DestinationPath "$global:WindowsNodeArtifactsZipFilePath" -Force

if (!(Test-Path($global:WindowsNodeArtifactsZipFilePath))) {
    throw "The file '$global:WindowsNodeArtifactsZipFilePath' that shall contain the artifacts for the Windows host could not be created."
}

Write-Log "Artifacts for the Windows host are available as '$global:WindowsNodeArtifactsZipFilePath'"

if (Test-Path($global:WindowsNodeArtifactsDownloadsDirectory)) {
    Write-Log "Remove folder '$global:WindowsNodeArtifactsDownloadsDirectory'"
    Remove-Item $global:WindowsNodeArtifactsDownloadsDirectory -Force -Recurse
}








