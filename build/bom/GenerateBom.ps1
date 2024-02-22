# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Generates the bom for the current repo

.DESCRIPTION
This script assists in the following actions:
- generate bom file for go projects
- generate bom file for the debian packages
- merge all bom files into one

.PARAMETER $Proxy
HTTP proxy to be used

.PARAMETER ShowLogs
Show all logs in terminal

.EXAMPLE
PS> .\build\bom\GenerateBom.ps1
#>

Param(
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)

# function EnsureNpm() {
#     Write-Output 'Check the existence of npm'
#     try
#     {
#         if(Get-Command "npme") { Write-Output "npm exists" }
#     }
#     catch
#     {
#         Write-Output "npm does not exist, installing it"
#         $CMD = 'choco'
#         $INSTALL = @('install', 'nodejs-lts', '-y')
#         Write-Output "npm install with: " $CMD $INSTALL
#         & $CMD $INSTALL

#         if($Proxy -ne '') {
#             $CMD = 'npm'
#             $SETPROXY = @('config', 'set', 'proxy', $Proxy)
#             Write-Output "proxy set with: " $CMD $SETPROXY
#             & $CMD $SETPROXY
#         }
#     }
#     Write-Output 'npm now available'
# }

function EnsureCdxgen() {
    Write-Output 'Check the existence of tool cdxgen'

    # download cdxgen
    $downloadFile = "$global:BinPath\cdxgen.exe"
    if (!(Test-Path $downloadFile)) {
        DownloadFile $downloadFile https://github.com/CycloneDX/cdxgen/releases/download/v10.1.3/cdxgen.exe $true -ProxyToUse $Proxy
    }
    Write-Output "cdxgen now available"
}

function EnsureCdxCli() {
    # download cli if not there
    $cli = "$global:BinPath\cyclonedx-win-x64.exe"
    if (!(Test-Path $cli)) {
        DownloadFile $cli https://github.com/CycloneDX/cyclonedx-cli/releases/download/v0.25.0/cyclonedx-win-x64.exe $true -ProxyToUse $Proxy
    }
}

function GenerateBomGolang($dirname) {
    Write-Output "Generate bom for directory: $dirname"

    $tempdir = "$bomRootDir\merge"
    New-Item $tempdir -ItemType Directory -ErrorAction SilentlyContinue
    $bomfile = "$tempdir\$($dirname.Split('\')[-1]).json"
    if (Test-Path $bomfile) {Remove-Item -Force $bomfile}
    $env:FETCH_LICENSE="true"
    if($Proxy -ne '') {
        $env:GLOBAL_AGENT_HTTP_PROXY=$Proxy
        $env:https_proxy=$Proxy
    }
    $env:SCAN_DEBUG_MODE='debug'
    $indir = $global:KubernetesPath+"\"+$dirname
    Write-Output "Generate $dirname with command 'cdxgen --required-only -o `"$bomfile`" `"$indir`"'"
    cdxgen --required-only -o `"$bomfile`" `"$indir`"

    Write-Output "bom now available: $bomfile"
}

function MergeBomFilesFromDirectory() {
    Write-Output "Merge bom files from '$bomRootDir\merge'"

    # cleanup files
    Remove-Item -Path "$bomRootDir\k2s-bom.json" -ErrorAction SilentlyContinue
    Remove-Item -Path "$bomRootDir\k2s-bom.xml" -ErrorAction SilentlyContinue

    # merge all files to one bom file
    $bomfiles = (Get-ChildItem -Path "$bomRootDir\merge" -Filter *.json -Recurse).FullName | Sort-Object length -Descending
    $CMD = 'cyclonedx-win-x64'
    $MERGE = @('merge', '--input-files')
    # adding at the beginning just to have the right naming for the component
    $MERGE += "`"$bomRootDir\merge\k2s-static.json`""
    foreach($bomfile in $bomfiles) { $MERGE += "`"$bomfile`"" }
    $MERGE += '--output-file'
    $MERGE += "`"$bomRootDir\k2s-bom.json`""
    & $CMD $MERGE

    # generate xml
    Write-Output "Create additional xml format file '$bomRootDir\k2s-bom.xml'"
    $COMPOSE = @('convert')
    $COMPOSE += '--input-file'
    $COMPOSE += "`"$bomRootDir\k2s-bom.json`""
    $COMPOSE += '--output-file'
    $COMPOSE += "`"$bomRootDir\k2s-bom.xml`""
    & $CMD $COMPOSE
}

function ValidateResultBom() {
    Write-Output "Validate bom file: '$bomRootDir\k2s-bom.json'"

    # build and execute validate command
    $CMD = 'cyclonedx-win-x64'
    $VALIDATE = @('validate', '--input-file', "`"$bomRootDir\k2s-bom.json`"", '--fail-on-errors')
    & $CMD $VALIDATE
}

function CheckVMState() {
    Write-Output "Check KubeMaster state"

    $vmState = (Get-VM -Name $global:VMName).State
    if ($vmState -ne [Microsoft.HyperV.PowerShell.VMState]::Running) {
        throw 'KubeMaster is not running, please start the cluster !'
    }
}

function GenerateBomDebian() {
    Write-Output "Generate bom for debian packages"

    Write-Output "Install npm"
    #ExecCmdMaster "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs npm"
    $hostname = Get-ControlPlaneNodeHostname
    Write-Output "Install cdxgen into $hostname"

    ExecCmdMaster "if test -f /usr/local/bin/cdxgen; then echo cdxgen exists; else sudo curl -L -o /usr/local/bin/cdxgen --proxy http://172.19.1.1:8181 https://github.com/CycloneDX/cdxgen/releases/download/v10.1.3/cdxgen; fi"
    ExecCmdMaster "sudo chmod +x /usr/local/bin/cdxgen"

    Write-Output "Generate bom for debian"
    ExecCmdMaster "sudo SCAN_DEBUG_MODE=debug FETCH_LICENSE=true DEBIAN_FRONTEND=noninteractive cdxgen --required-only -t os --deep -o kubemaster.json 2>&1"

    Write-Output "Copy bom file to local folder"
    $source = "$global:Remote_Master" + ':/home/remote/kubemaster.json'
    Copy-FromToMaster -Source $source -Target "$bomRootDir\merge"
}

# function FilterBomForSw360Import() {
#     Write-Output "Filter and patch for VCS string for all components started.."

#     Write-Output "Check availability of sbomgenerator.exe under location $bomRootDir\generator"
#     $inputFile = "$bomRootDir\k2s-bom.xml"
#     $dataFile = "$bomRootDir\generator\data.json"
#     $outFile = "$bomRootDir\k2s-filtered.xml"

#     $executablePath = "$bomRootDir\generator\sbomgenerator.exe"
#     $argument = @('-f', $inputFile, '-d', $dataFile, '-o', $outFile)

#     if (Test-Path "$bomRootDir\generator\sbomgenerator.exe") {
#         & cmd /c "$executablePath $argument 2>&1"
#     } else {
#         Write-Warning "Unable to find sbomgenerator!! Please fix it!!"
#     }
# }

#################################################################################################
# SCRIPT START                                                                                  #
#################################################################################################

# load global settings
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1

# import global functions
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1

$bomRootDir = "$global:KubernetesPath\build\bom"

$ErrorActionPreference = 'Stop'

if ($Trace) {
    Set-PSDebug -Trace 1
}

Write-Output '---------------------------------------------------------------'
Write-Output ' Generation of bom file started.'
Write-Output '---------------------------------------------------------------'

$generationStopwatch = [system.diagnostics.stopwatch]::StartNew()

CheckVMState
EnsureCdxgen
EnsureCdxCli
GenerateBomGolang("pkg\util\cloudinitisobuilder")
GenerateBomGolang("pkg\util\zap")
GenerateBomGolang("pkg\network\bridge")
GenerateBomGolang("pkg\network\devgon")
GenerateBomGolang("pkg\network\httpproxy")
GenerateBomGolang("pkg\network\vfprules")
GenerateBomGolang("pkg\k2s")

GenerateBomDebian
MergeBomFilesFromDirectory

# ValidateResultBom

Write-Output '---------------------------------------------------------------'
Write-Output " Generate bom file finished.   Total duration: $('{0:hh\:mm\:ss}' -f $generationStopwatch.Elapsed )"
Write-Output '---------------------------------------------------------------'