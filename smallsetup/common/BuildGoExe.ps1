# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Builds GO executable

.DESCRIPTION
Helps in building several GO executables which is provided from K2s.
bridge.exe, cloudinitisobuilder.exe, devgon.exe, httpproxy.exe, k2s.exe, vfprules.exe
Provides options to inject flags for an executable.

.EXAMPLE
PS> .\common\BuildGoExe.ps1

PS> .\common\BuildGoExe.ps1 -ProjectDir "c:\k\httproxy"

PS> .\common\BuildGoExe.ps1 -ProjectDir "c:\k\devgon" -ExeOutDir "c:\k\bin"

#>

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Folder path of GO project')]
    [string] $ProjectDir,
    [parameter(Mandatory = $false, HelpMessage = 'Folder path where executable shall be dumped')]
    [string] $ExeOutDir,
    [parameter(Mandatory = $false, HelpMessage = 'Build all K2s executables with assumption all are under single git repository')]
    [bool] $BuildAll
)

# load global settings
&$PSScriptRoot\GlobalVariables.ps1

function Add-GoExecutableToList($location, $outLocation) {
    $goExecutable = [PSCustomObject]@{
        InDir  = $location
        OutDir = $outLocation
    }
    return $goExecutable
}

$buildStopwatch = [system.diagnostics.stopwatch]::StartNew()

$currentLocation = Get-Location
$rootGoDir = 'pkg'
$networkGoDir = 'network'
$utilGoDir = 'util'
$k2sDir = 'k2s'

if ($ProjectDir -eq '') {
    $ProjectDir = [IO.Path]::Combine($global:KubernetesPath, $rootGoDir, $k2sDir)
}

if ($ExeOutDir -eq '') {
    $ExeOutDir = "$global:KubernetesPath"
}

#Initial directory to collect git details
Set-Location $ProjectDir

#boringcrypto for FIPS compliance, needs GO 1.19.4 or higher
$Env:GOEXPERIMENT = 'boringcrypto';

#VERSION
$Version = Get-Content -Path $global:KubernetesPath\VERSION
Write-Output "VERSION: $Version ..."

#BUILD DATE
$BUILD_DATE = Get-date -UFormat +'%Y-%m-%dT%H:%M:%SZ'
Write-Output "BUILD_DATE: $BUILD_DATE"

# GIT COMMIT
$GIT_COMMIT = $(git rev-parse HEAD)
Write-Output "GIT_COMMIT: $GIT_COMMIT"

# GIT TREE STATE AND TAG
$GIT_TAG = ''
$GIT_TREE_STATE = 'clean'

if ($null -ne $(git status --porcelain)) {
    $GIT_TREE_STATE = 'dirty'
}
else {
    # We have a clean tree state check for tags to declare official release
    $GIT_TAG = git describe --exact-match --tags HEAD 2>&1
    if (!$?) {
        $GIT_TAG = ''
        Write-Output 'No tag found for the git commit'
    }
    else {
        Write-Output "GIT_TAG: $GIT_TAG"
    }
}

Write-Output "GIT_TREE_STATE: $GIT_TREE_STATE"

$goExecutables = @()

#Input Directories
$k2sDir = [IO.Path]::Combine($global:KubernetesPath, $rootGoDir, $k2sDir)
$httpproxyDir = [IO.Path]::Combine($global:KubernetesPath, $rootGoDir, $networkGoDir, 'httpproxy')
$devgonDir = [IO.Path]::Combine($global:KubernetesPath, $rootGoDir, $networkGoDir, 'devgon')

$cloudinitisobuilderDir = [IO.Path]::Combine($global:KubernetesPath, $rootGoDir, $utilGoDir, 'cloudinitisobuilder')
$zapDir = [IO.Path]::Combine($global:KubernetesPath, $rootGoDir, $utilGoDir, 'zap')
$yaml2jsonDir = [IO.Path]::Combine($global:KubernetesPath, $rootGoDir, $utilGoDir, 'yaml2json')

$vfprulesDir = [IO.Path]::Combine($global:KubernetesPath, $rootGoDir, $networkGoDir, 'vfprules')
$bridgeDir = [IO.Path]::Combine($global:KubernetesPath, $rootGoDir, $networkGoDir, 'bridge')

#Output Directories
$binDir = [IO.Path]::Combine($global:KubernetesPath, 'bin')
$cniBinDir = [IO.Path]::Combine($global:KubernetesPath, 'bin', 'cni')


if ($BuildAll) {
    $goExecutables += Add-GoExecutableToList $k2sDir "$global:KubernetesPath"

    $goExecutables += Add-GoExecutableToList $httpproxyDir $binDir
    $goExecutables += Add-GoExecutableToList $devgonDir $binDir
    $goExecutables += Add-GoExecutableToList $cloudinitisobuilderDir $binDir
    $goExecutables += Add-GoExecutableToList $zapDir $binDir
    $goExecutables += Add-GoExecutableToList $yaml2jsonDir $binDir

    $goExecutables += Add-GoExecutableToList $vfprulesDir $cniBinDir
    $goExecutables += Add-GoExecutableToList $bridgeDir $cniBinDir
}
else {
    # Single executable build
    $goExecutables += Add-GoExecutableToList $ProjectDir $ExeOutDir
}

for ($i = 0; $i -lt $goExecutables.Count; $i++) {
    $goExecutable = $goExecutables[$i]

    Write-Output "Building GO executable under folder path: $($goExecutable.InDir) ..."
    Set-Location $($goExecutable.InDir)

    # GO BUILD
    $Env:GOOS = 'windows'
    $Env:GOARCH = 'amd64'
    go build -ldflags "-s -w  `
    -X base/version.version=$($Version) `
    -X base/version.buildDate=$($BUILD_DATE)  `
    -X base/version.gitCommit=$($GIT_COMMIT)  `
    -X base/version.gitTag=$($GIT_TAG) `
    -X base/version.gitTreeState=$($GIT_TREE_STATE)" `
        -gcflags=all="-l -B" `
        -o "$($goExecutable.OutDir)" `

    if (!$?) {
        Set-Location $currentLocation
        throw 'Build failed!'
    }

    Write-Output "ExeOutDir: `"$($goExecutable.OutDir)`""
}

Set-Location $currentLocation

Write-Output '---------------------------------------------------------------'
Write-Output " Build finished.   Total duration: $('{0:hh\:mm\:ss}' -f $buildStopwatch.Elapsed )"
Write-Output '---------------------------------------------------------------'