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

Generate SBOM with annotations for clearance purpose
PS> .\build\bom\GenerateBom.ps1 -Annotate

Generate SBOM with annotations for clearance for specific addons
PS> .\build\bom\GenerateBom.ps1 -Annotate -Addons registry,traefik
#>

Param(
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If true, final SBOM file will have component annotations, this is required only for component clearance')]
    [switch] $Annotate = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Name of Addons to include for SBOM generation')]
    [string[]] $Addons
)

function EnsureTrivy() {
    Write-Output 'Check the existence of tool trivy'

    # download trivy
    $downloadFile = "$global:BinPath\trivy.exe"
    if ((Test-Path $downloadFile)) {
        Write-Output 'trivy already available'
        return
    }

    $compressedFile = "$global:BinPath\trivy.zip"
    DownloadFile $compressedFile 'https://github.com/aquasecurity/trivy/releases/download/v0.52.1/trivy_0.52.1_windows-64bit.zip' $true -ProxyToUse $Proxy

    # Extract the archive.
    Write-Output "Extract archive to '$global:BinPath"
    $ErrorActionPreference = 'SilentlyContinue'
    tar C `"$global:BinPath`" -xvf `"$compressedFile`" trivy.exe 2>&1 | % { "$_" }
    $ErrorActionPreference = 'Stop'

    Remove-Item -Path "$compressedFile" -Force -ErrorAction SilentlyContinue

    Write-Output 'trivy now available'
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
    Write-Output "Generate $dirname with command 'trivy.exe fs `"$indir`"' --scanners license --license-full --format cyclonedx -o `"$bomfile`" "
    trivy.exe fs `"$indir`" --scanners license --license-full --format cyclonedx -o `"$bomfile`"

    if ($Annotate) {
        Write-Output "Enriching generated sbom with command 'sbomgenerator.exe -e `"$bomfile`" "
        &"$bomRootDir\sbomgenerator.exe" -e `"$bomfile`"
    }

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

    $hostname = Get-ControlPlaneNodeHostname

    $trivyInstalled = $(ExecCmdMaster 'which /usr/local/bin/trivy' -NoLog)
    if ($trivyInstalled -match '/bin/trivy') {
        Write-Output "Trivy already available in VM $hostname"
    }
    else {
        Write-Output "Install trivy into $hostname"
        ExecCmdMaster 'sudo curl --proxy http://172.19.1.1:8181 -sLO https://github.com/aquasecurity/trivy/releases/download/v0.52.1/trivy_0.52.1_Linux-64bit.tar.gz 2>&1'
        ExecCmdMaster 'sudo tar -xzf ./trivy_0.52.1_Linux-64bit.tar.gz trivy'
        ExecCmdMaster 'sudo rm ./trivy_0.52.1_Linux-64bit.tar.gz'
        ExecCmdMaster 'sudo mv ./trivy /usr/local/bin/'
        ExecCmdMaster 'sudo chmod +x /usr/local/bin/trivy'
    }

    Write-Output 'Generate bom for debian'
    ExecCmdMaster 'sudo HTTPS_PROXY=http://172.19.1.1:8181 trivy rootfs / --scanners license --license-full --format cyclonedx -o kubemaster.json 2>&1'

    Write-Output 'Copy bom file to local folder'
    $source = "$global:Remote_Master" + ':/home/remote/kubemaster.json'
    Copy-FromToMaster -Source $source -Target "$bomRootDir\merge"

    if ($Annotate) {
        $kubeSBOMJsonFile = "$bomRootDir\merge\kubemaster.json"
        Write-Output "Enriching generated sbom with command 'sbomgenerator.exe -e `"$kubeSBOMJsonFile`" "
        &"$bomRootDir\sbomgenerator.exe" -e `"$kubeSBOMJsonFile`"
    }
}

function LoadK2sImages() {
    Write-Output 'Generate bom for container images'

    $tempDir = [System.Environment]::GetEnvironmentVariable('TEMP')

    # dump all images
    &$bomRootDir\DumpK2sImages.ps1 -Addons $Addons

    # export all addons to have all images pull
    Write-Output "Exporting addons to trigger pulling of containers under $tempDir"

    &k2s.exe addons export $Addons -d $tempDir -o
    if ( Test-Path -Path $tempDir\addons.zip) {
        Remove-Item -Path $tempDir\addons.zip -Force
    }

    Write-Output 'Containers images now available'
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
    $imageType = $jsonContent.ImageType
    $imagesWindows = @()
    for ($i = 0 ; $i -lt $imagesName.Count ; $i++) {
        $name = $imagesName[$i]
        $version = $imagesVersion[$i]
        $type = $imageType[$i]
        $fullname = $name + ':' + $version
        Write-Output "Processing image: ${fullname} with type $type"

        # find image id in kubemaster VM
        $imageId = ExecCmdMaster "sudo buildah images -f reference=${fullname} --format '{{.ID}}'"
        Write-Output "  -> Image Id: $imageId"

        #check if image id is not empty
        if (![string]::IsNullOrEmpty($imageId)) {
            # create bom file entry for linux image
            Write-Output "  -> Image ${fullname} is linux image, creating bom file"
            # replace in string / with - to avoid issues with file name
            $imageName = 'c-' + $name -replace '/', '-'
            ExecCmdMaster "sudo rm -f /home/remote/$imageName.tar"
            ExecCmdMaster "sudo rm -f $imageName.json"
            Write-Output "  -> Create bom file for image $imageName"
            Write-Output "  -> sudo buildah push $imageId docker-archive:/home/remote/$imageName.tar:${fullname}"
            $ret = ExecCmdMaster "sudo buildah push $imageId docker-archive://home/remote/$imageName.tar:${fullname} 2>&1" -NoLog
            Write-Output "  -> $ret"

            # create bom file entry for linux image
            # TODO: with license it does not work yet from cdxgen point of view
            #ExecCmdMaster "sudo GLOBAL_AGENT_HTTP_PROXY=http://172.19.1.1:8181 SCAN_DEBUG_MODE=debug FETCH_LICENSE=true DEBIAN_FRONTEND=noninteractive cdxgen --required-only -t containerfile $imageId.tar -o $imageName.json"
            k2s system ssh m -- "sudo HTTPS_PROXY=http://172.19.1.1:8181 trivy image --input $imageName.tar --scanners license --license-full --format cyclonedx -o $imageName.json 2>&1"
            # copy bom file to local folder
            $source = "$global:Remote_Master" + ":/home/remote/$imageName.json"
            Copy-FromToMaster -Source $source -Target "$bomRootDir\merge"

            if ($Annotate) {
                $imageSBOMJsonFile = "$bomRootDir\merge\$imageName.json"
                Write-Output "Enriching generated sbom with command 'sbomgenerator.exe -e `"$imageSBOMJsonFile`" -t `"$type`" -c `"$version`" "
                &"$bomRootDir\sbomgenerator.exe" -e `"$imageSBOMJsonFile`" -t `"$type`" -c `"$version`"
            }

            # delete tar file
            ExecCmdMaster "sudo rm -f $imageName.tar"
            ExecCmdMaster "sudo rm -f $imageName.json"
        }
        else {
            Write-Output '  -> Image is windows image, skipping'
            $imageObject = [PSCustomObject]@{
                ImageName    = $name
                ImageType    = $type
                ImageVersion = $version
            }
            $imagesWindows += $imageObject
        }
    }

    # iterate through windows images
    $ims = (&k2s.exe image ls -o json | ConvertFrom-Json).containerimages

    for ($j = 0; $j -lt $imagesWindows.Count; $j++) {
        $image = $imagesWindows[$j].ImageName
        $type = $imagesWindows[$j].ImageType
        $version = $imagesWindows[$j].ImageVersion
        Write-Output "Processing windows image: $image, Image Type: $type"

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
        k2s system ssh m -- "sudo HTTPS_PROXY=http://172.19.1.1:8181 trivy image --input $imageName.tar --scanners license --license-full --format cyclonedx -o $imageName.json 2>&1"

        # copy bom file to local folder
        $source = "$global:Remote_Master" + ":/home/remote/$imageName.json"
        Copy-FromToMaster -Source $source -Target "$bomRootDir\merge"

        if ($Annotate) {
            $imageSBOMJsonFile = "$bomRootDir\merge\$imageName.json"
            Write-Output "Enriching generated sbom with command 'sbomgenerator.exe -e `"$imageSBOMJsonFile`" -t `"$type`" -c `"$version`""
            &"$bomRootDir\sbomgenerator.exe" -e `"$imageSBOMJsonFile`" -t `"$type`" -c `"$version`"
        }

        # remove tar file
        ExecCmdMaster "sudo rm /home/remote/$imageName.tar"
        Remove-Item -Path "$tempDir\\$imageName.tar" -Force
    }

    Write-Output 'Containers bom files now available'
}

function RemoveOldContainerFiles() {
    Write-Output 'Remove old container files'

    $path = "$bomRootDir\merge"
    # cleanup files except k2s-static.json and k2s-static.json.license and surpress errors
    Get-ChildItem -Path $path -Recurse -Exclude 'k2s-static.json', 'k2s-static.json.license' | Remove-Item -Force -ErrorAction SilentlyContinue
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
Write-Output 'Generation of bom file started.'
Write-Output '---------------------------------------------------------------'

if ($Annotate) {
    Write-Output 'Annotation of SBOM enabled.'
    if (!(Test-Path "$bomRootDir\sbomgenerator.exe")) {
        throw "sbomgenerator.exe is not present under directory $bomRootDir"
    }
}

if ($Addons) {
    Write-Output "Generating SBOM for addons '$Addons'"
} else {
    Write-Output "Generating SBOM for all the available addons"
}

$generationStopwatch = [system.diagnostics.stopwatch]::StartNew()

CheckVMState
EnsureTrivy
EnsureCdxCli
RemoveOldContainerFiles
GenerateBomGolang('k2s')
GenerateBomDebian
LoadK2sImages
GenerateBomContainers
MergeBomFilesFromDirectory

Write-Output '---------------------------------------------------------------'
Write-Output " Generate bom file finished.   Total duration: $('{0:hh\:mm\:ss}' -f $generationStopwatch.Elapsed )"
Write-Output '---------------------------------------------------------------'
