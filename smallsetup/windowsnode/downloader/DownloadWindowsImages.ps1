# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy = ''
)

&$PSScriptRoot\..\WindowsNodeCommonVariables.ps1
. $PSScriptRoot\..\..\common\GlobalFunctions.ps1

$ErrorActionPreference = 'Stop'

function GetStringFromText([string]$text, [string]$searchPattern) {
    [regex]$rx = $searchPattern
    $foundValue = ""
    $result = $rx.match($text)
    if ($result.Success -and $result.Groups.Count -gt 1) {
        $foundValue = $result.Groups[1].Value
    }
    return $foundValue
}

function DownloadWindowsImages($baseDirectory) {
    $tomlFilePath = "$global:KubernetesPath\cfg\containerd\config.toml"
    if (!(Test-Path -Path $tomlFilePath)) {
        throw "The expected file '$tomlFilePath' is not available"
    }

    $tomlContent = Get-Content -Path "$tomlFilePath"

    $sandboxImageName = GetStringFromText $tomlContent 'sandbox_image = "([^"]*)"'
    if ($sandboxImageName -eq "") {
        throw "The sandbox image name gathered from the file '$tomlFilePath' is empty"
    }

    Write-Log "Create folder '$baseDirectory'"
    mkdir $baseDirectory | Out-Null
    Write-Log "Pull image '$sandboxImageName' from repository using proxy:$Proxy"

    $initialized = $false
    $imagePulledSuccessfully = $false

    $HttpProxyVariableOriginalValue = $env:HTTP_PROXY
    $HttpsProxyVariableOriginalValue = $env:HTTPS_PROXY
    try {
        $env:HTTP_PROXY=$Proxy
        $env:HTTPS_PROXY=$Proxy

        $retryNumber = 0
        $maxAmountOfRetries = 3
        $waitTimeInSeconds = 2

        # check whether containerd is initialized and connection works
        while ($retryNumber -lt $maxAmountOfRetries) {
            try {
                &$global:NerdctlExe -n="k8s.io" image ls | Out-Null
                if (!$?) {
                    throw
                }
                $initialized = $true
                break;
            }
            catch {
                Write-Log "Containerd is not initialized yet. Waiting $waitTimeInSeconds seconds to try again"
                $retryNumber++
                Start-Sleep -Seconds $waitTimeInSeconds
            }
        }
        if (!$initialized) {
            Write-Log "Containerd is not initialized yet after $maxAmountOfRetries tries."
        }

        # Now really pull image and ignore errors from ctr
        $ErrorActionPreference = 'Continue'
        &$global:NerdctlExe -n="k8s.io" pull $sandboxImageName --all-platforms 2>&1 | Out-Null
        $images = &$global:CtrExe -n="k8s.io" image ls | Out-String

        if ($images.Contains($sandboxImageName)) {
            $imagePulledSuccessfully = $true
        }
    }
    finally {
        $env:HTTP_PROXY=$HttpProxyVariableOriginalValue
        $env:HTTPS_PROXY=$HttpsProxyVariableOriginalValue
    }

    $ErrorActionPreference = 'Stop'

    if ($imagePulledSuccessfully) {
        $tarFileName = $sandboxImageName.Replace(":", "_").Replace("/", "__") + ".tar"
        $tarFilePath = "$baseDirectory\$tarFileName"

        if (Test-Path -Path $tarFilePath -PathType 'Leaf' -ErrorAction Stop) {
            Write-Log "File '$tarFilePath' already exists. Deleting it"
            Remove-Item -Path $tarFilePath -Force -ErrorAction Stop
            Write-Log "  done"
        }

        Write-Log "Export image '$sandboxImageName' to '$tarFilePath'"
        &$global:NerdctlExe -n="k8s.io" save -o `"$tarFilePath`" "$sandboxImageName"
        if (!$?) {
            throw "The image '$sandboxImageName' could not be exported"
        }
        Write-Log "Image '$sandboxImageName' available as '$tarFilePath'"
    } else {
        $filePath = "$baseDirectory\TheImageCouldNotBePulled.txt"
        Write-Log "The image '$sandboxImageName' could not be pulled. The placeholder file '$filePath' will be written instead."
        New-Item -Path $filePath | Out-Null
    }
}

$downloadsBaseDirectory = "$global:WindowsNodeArtifactsDownloadsDirectory"
if (!(Test-Path $downloadsBaseDirectory)) {
    Write-Log "Create folder '$downloadsBaseDirectory'"
    New-Item -Force -Path $downloadsBaseDirectory -ItemType Directory
}

$windowsImagesDownloadsDirectory = "$downloadsBaseDirectory\$global:WindowsNode_ImagesDirectory"

DownloadWindowsImages($windowsImagesDownloadsDirectory)

