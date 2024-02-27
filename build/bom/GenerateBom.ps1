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

function EnsureCdxgen() {
    Write-Output 'Check the existence of tool cdxgen'

    # download cdxgen
    $downloadFile = "$global:BinPath\cdxgen.exe"
    if (!(Test-Path $downloadFile)) {
        DownloadFile $downloadFile https://github.com/CycloneDX/cdxgen/releases/download/v10.1.3/cdxgen.exe $true -ProxyToUse $Proxy
    }
    Write-Output 'cdxgen now available'
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
    if (Test-Path $bomfile) { Remove-Item -Force $bomfile }
    $env:FETCH_LICENSE = 'true'
    if ($Proxy -ne '') {
        $env:GLOBAL_AGENT_HTTP_PROXY = $Proxy
        $env:https_proxy = $Proxy
    }
    $env:SCAN_DEBUG_MODE = 'debug'
    $indir = $global:KubernetesPath + '\' + $dirname
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
    foreach ($bomfile in $bomfiles) { $MERGE += "`"$bomfile`"" }
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
    Write-Output 'Check KubeMaster state'

    $vmState = (Get-VM -Name $global:VMName).State
    if ($vmState -ne [Microsoft.HyperV.PowerShell.VMState]::Running) {
        throw 'KubeMaster is not running, please start the cluster !'
    }
}

function GenerateBomDebian() {
    Write-Output 'Generate bom for debian packages'

    Write-Output 'Install npm'
    #ExecCmdMaster "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs npm"
    $hostname = Get-ControlPlaneNodeHostname
    Write-Output "Install cdxgen into $hostname"

    ExecCmdMaster 'if test -f /usr/local/bin/cdxgen; then echo cdxgen exists; else sudo curl -L -o /usr/local/bin/cdxgen --proxy http://172.19.1.1:8181 https://github.com/CycloneDX/cdxgen/releases/download/v10.1.3/cdxgen; fi'
    ExecCmdMaster 'sudo chmod +x /usr/local/bin/cdxgen'

    Write-Output 'Generate bom for debian'
    ExecCmdMaster 'sudo SCAN_DEBUG_MODE=debug FETCH_LICENSE=true DEBIAN_FRONTEND=noninteractive cdxgen --required-only -t os --deep -o kubemaster.json 2>&1'

    Write-Output 'Copy bom file to local folder'
    $source = "$global:Remote_Master" + ':/home/remote/kubemaster.json'
    Copy-FromToMaster -Source $source -Target "$bomRootDir\merge"
}

function DumpK2sImages() {
    Write-Output 'Generate bom for container images'

    $tempDir = [System.Environment]::GetEnvironmentVariable('TEMP')

    # export all addons to have all images pull
    Write-Output "Writing to temp all containers $tempDir"
    &k2s.exe addons export -d $tempDir -o
    if ( Test-Path -Path $tempDir\addons.zip) {
        Remove-Item -Path $tempDir\addons.zip -Force
    }

    # dump all images 
    &$bomRootDir\Dumpk2sImages.ps1
}

function GenerateBomContainers() {
    Write-Output 'Generate bom for container images'

    $tempDir = [System.Environment]::GetEnvironmentVariable('TEMP')

    # read json file and iterate through entries, filter out windows images   
    $jsonFile = "$bomRootDir\container-images-used.json"
    Write-Output "Start generating bom for container images from $jsonFile"
    $jsonContent = Get-Content -Path $jsonFile | ConvertFrom-Json
    $imagesName = $jsonContent.ImageName
    $imagesVersion = $jsonContent.ImageVersion
    $imagesWindows = @()
    for ($i = 0 ; $i -lt $imagesName.Count ; $i++) {
        $name = $imagesName[$i]
        $version = $imagesVersion[$i]
        $fullname = $name + ':' + $version
        Write-Output "Processing image: ${fullname}"

        # find image id in kubemaster VM
        $imageId = ExecCmdMaster "sudo buildah images -f reference=${fullname} --format '{{.ID}}'"
        Write-Output "  -> Image Id: $imageId"

        #check if image id is not empty
        if (![string]::IsNullOrEmpty($imageId)) {
            # create bom file entry for linux image
            Write-Output "  -> Image ${fullname} is linux image, creating bom file"
            # replace in string / with - to avoid issues with file name            
            $imageName = 'c-' + $name -replace '/', '-'
            ExecCmdMaster "sudo rm -f $imageName.tar"
            ExecCmdMaster "sudo rm -f $imageName.json"
            Write-Output "  -> Create bom file for image $imageName"
            Write-Output "  -> sudo buildah push $imageId docker-archive:$imageName.tar:${fullname}"
            ExecCmdMaster "sudo buildah push $imageId docker-archive:$imageName.tar:${fullname}"

            # create bom file entry for linux image
            # TODO: with license it does not work yet from cdxgen point of view
            #ExecCmdMaster "sudo GLOBAL_AGENT_HTTP_PROXY=http://172.19.1.1:8181 SCAN_DEBUG_MODE=debug FETCH_LICENSE=true DEBIAN_FRONTEND=noninteractive cdxgen --required-only -t containerfile $imageId.tar -o $imageName.json"
            ExecCmdMaster "sudo GLOBAL_AGENT_HTTP_PROXY=http://172.19.1.1:8181 SCAN_DEBUG_MODE=debug DEBIAN_FRONTEND=noninteractive cdxgen --required-only -t containerfile $imageName.tar -o $imageName.json"

            # copy bom file to local folder
            $source = "$global:Remote_Master" + ":/home/remote/$imageName.json"
            Copy-FromToMaster -Source $source -Target "$bomRootDir\merge"

            # delete tar file
            ExecCmdMaster "sudo rm -f $imageName.tar"
            ExecCmdMaster "sudo rm -f $imageName.json"
        }
        else {
            Write-Output '  -> Image is windows image, skipping'
            $imagesWindows += $name
        }
    }

    # iterate through windows images
    $ims = (&k2s.exe image ls -o json | ConvertFrom-Json).containerimages
    foreach ($image in $imagesWindows) {
        Write-Output "Processing windows image: $image"
        if ($image.length -eq 0) {
            Write-Output 'Ignoring emtpy image name'
            continue
        }
        $imageName = 'c-' + $image -replace '/', '-'
        
        # filter from $ims objects with propeerty repository equal to $image    
        $img = $ims | Where-Object { $_.repository -eq $image }
        if ( $null -eq $img) {
            throw "Image $image not found in k2s, please correct static image list with real used containers !"
        }

        # copy to master
        Write-Output "  -> Exporting windows image: $imageName with id: $img.imageid to $tempDir\$imageName.tar"
        &k2s.exe image export --id $img.imageid -t "$tempDir\\$imageName.tar" --docker-archive 

        # copy to master since cdxgen is not available on windows
        Write-Output "  -> Copied to kubemaster: $imageName.tar"
        &k2s.exe system scp m "$tempDir\\$imageName.tar" '/home/remote'

        Write-Output "  -> Creating bom for windows image: $imageName"
        # TODO: with license it does not work yet from cdxgen point of view
        #ExecCmdMaster "sudo GLOBAL_AGENT_HTTP_PROXY=http://172.19.1.1:8181 SCAN_DEBUG_MODE=debug FETCH_LICENSE=true DEBIAN_FRONTEND=noninteractive cdxgen --required-only -t containerfile /home/remote/$imageName.tar -o $imageName.json" -IgnoreErrors -NoLog | Out-Null
        ExecCmdMaster "sudo GLOBAL_AGENT_HTTP_PROXY=http://172.19.1.1:8181 SCAN_DEBUG_MODE=debug DEBIAN_FRONTEND=noninteractive cdxgen --required-only -t containerfile /home/remote/$imageName.tar -o $imageName.json" -IgnoreErrors -NoLog | Out-Null

        # copy bom file to local folder
        $source = "$global:Remote_Master" + ":/home/remote/$imageName.json"
        Copy-FromToMaster -Source $source -Target "$bomRootDir\merge"

        # remove tar file
        ExecCmdMaster "sudo rm /home/remote/$imageName.tar"
        Remove-Item -Path "$tempDir\\$imageName.tar" -Force    
    }

    Write-Output 'Containers bom files now available'
}

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
GenerateBomGolang('pkg\util\cloudinitisobuilder')
GenerateBomGolang('pkg\util\zap')
GenerateBomGolang('pkg\network\bridge')
GenerateBomGolang('pkg\network\devgon')
GenerateBomGolang('pkg\network\httpproxy')
GenerateBomGolang('pkg\network\vfprules')
GenerateBomGolang('pkg\k2s')

GenerateBomDebian
DumpK2sImages
GenerateBomContainers
MergeBomFilesFromDirectory

# ValidateResultBom

Write-Output '---------------------------------------------------------------'
Write-Output " Generate bom file finished.   Total duration: $('{0:hh\:mm\:ss}' -f $generationStopwatch.Elapsed )"
Write-Output '---------------------------------------------------------------'