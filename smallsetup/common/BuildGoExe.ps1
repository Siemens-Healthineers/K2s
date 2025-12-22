# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
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

PS> .\common\BuildGoExe.ps1 -ProjectDir "c:\ws\k2s\k2s\cmd\httproxy"

PS> .\common\BuildGoExe.ps1 -ProjectDir "c:\ws\k2s\k2s\cmd\devgon" -ExeOutDir "c:\ws\k2s\bin"

#>

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Folder path of GO project')]
    [string] $ProjectDir,
    [parameter(Mandatory = $false, HelpMessage = 'Folder path where executable shall be dumped')]
    [string] $ExeOutDir,
    [parameter(Mandatory = $false, HelpMessage = 'Build all K2s executables with assumption all are under single git repository')]
    [switch] $BuildAll,
    [parameter(Mandatory = $false, HelpMessage = 'Proxy URL for Go operations (e.g., http://proxy.example.com:8080)')]
    [string] $Proxy
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
$appsDir = [IO.Path]::Combine($global:KubernetesPath, 'k2s', 'cmd')
$binDir = [IO.Path]::Combine($global:KubernetesPath, 'bin')
$cniBinDir = [IO.Path]::Combine($binDir, 'cni')
$appsOutputMapping = @{
    'bridge'              = $cniBinDir;
    'l4proxy'             = $cniBinDir;
    'cloudinitisobuilder' = $binDir;
    'devgon'              = $binDir;
    'httpproxy'           = $binDir;
    'k2s'                 = "$global:KubernetesPath"
    'vfprules'            = $cniBinDir
    'yaml2json'           = $binDir
    'zap'                 = $binDir
    'cplauncher'          = $cniBinDir
}

if ($ProjectDir -eq '') {
    $ProjectDir = [IO.Path]::Combine($appsDir, 'k2s')
}

if ($ExeOutDir -eq '') {
    $ExeOutDir = "$global:KubernetesPath"
}

#Initial directory to collect git details
Set-Location $ProjectDir

#boringcrypto for FIPS compliance, needs GO 1.19.4 or higher
$Env:GOEXPERIMENT = 'boringcrypto';

# Set proxy environment variables if Proxy parameter is provided
if ($Proxy) {
    Write-Output "Using proxy: $Proxy"
    $Env:HTTP_PROXY = $Proxy
    $Env:HTTPS_PROXY = $Proxy
}

#VERSION
$Version = Get-Content -Path $global:KubernetesPath\VERSION
Write-Output "VERSION: $Version"

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

if ($BuildAll -eq $true) {
    foreach ($appMapping in $appsOutputMapping.GetEnumerator()) {
        $inputDir = [IO.Path]::Combine($appsDir, $appMapping.Name)
        $goExecutables += Add-GoExecutableToList $inputDir $appMapping.Value
    }
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
    -X github.com/siemens-healthineers/k2s/internal/version.version=$($Version) `
    -X github.com/siemens-healthineers/k2s/internal/version.buildDate=$($BUILD_DATE)  `
    -X github.com/siemens-healthineers/k2s/internal/version.gitCommit=$($GIT_COMMIT)  `
    -X github.com/siemens-healthineers/k2s/internal/version.gitTag=$($GIT_TAG) `
    -X github.com/siemens-healthineers/k2s/internal/version.gitTreeState=$($GIT_TREE_STATE)" `
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