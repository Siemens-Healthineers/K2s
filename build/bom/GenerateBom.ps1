# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
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
#>

Param(
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If true, final SBOM file will have component annotations, this is required only for component clearance')]
    [switch] $Annotate = $false
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
    DownloadFile $compressedFile 'https://github.com/aquasecurity/trivy/releases/download/v0.69.1/trivy_0.69.1_windows-64bit.zip' $true -ProxyToUse $Proxy

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
        DownloadFile $cli https://github.com/CycloneDX/cyclonedx-cli/releases/download/v0.29.1/cyclonedx-win-x64.exe $true -ProxyToUse $Proxy
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

function Update-K2sStaticVersion() {
    Write-Output 'Update k2s-static.json with current version from VERSION file'

    # Read version from VERSION file
    $versionFile = "$global:KubernetesPath\VERSION"
    if (!(Test-Path $versionFile)) {
        throw "VERSION file not found at: $versionFile"
    }
    
    $version = (Get-Content -Path $versionFile -Raw).Trim()
    Write-Output "  -> K2s version from VERSION file: $version"
    
    # Update k2s-static.json with the version
    $staticJsonPath = "$bomRootDir\merge\k2s-static.json"
    if (!(Test-Path $staticJsonPath)) {
        throw "k2s-static.json not found at: $staticJsonPath"
    }
    
    $jsonContent = Get-Content -Path $staticJsonPath -Raw
    $jsonContent = $jsonContent -replace '"version":\s*"VERSION_PLACEHOLDER"', "`"version`": `"v$version`""
    Set-Content -Path $staticJsonPath -Value $jsonContent -NoNewline
    
    Write-Output "  -> Updated k2s-static.json with version: v$version"
}

function MergeBomFilesFromDirectory() {
    Write-Output "Merge bom files from '$bomRootDir\merge'"

    # cleanup files
    Remove-Item -Path "$bomRootDir\k2s-bom.json" -ErrorAction SilentlyContinue
    Remove-Item -Path "$bomRootDir\k2s-bom.xml" -ErrorAction SilentlyContinue

    # merge all files to one bom file
    $bomfiles = (Get-ChildItem -Path "$bomRootDir\merge" -Filter *.json -Recurse).FullName | Sort-Object length -Descending
    $CMD = "$global:BinPath\cyclonedx-win-x64"
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
    
    # Restore placeholder in k2s-static.json to keep file clean in git
    Write-Output "Restore VERSION_PLACEHOLDER in k2s-static.json"
    $staticJsonPath = "$bomRootDir\merge\k2s-static.json"
    $jsonContent = Get-Content -Path $staticJsonPath -Raw
    $jsonContent = $jsonContent -replace '"version":\s*"v[\d\.]+(-[\w\.]+)?"', "`"version`": `"VERSION_PLACEHOLDER`""
    Set-Content -Path $staticJsonPath -Value $jsonContent -NoNewline
}

function ValidateResultBom() {
    Write-Output "Validate bom file: '$bomRootDir\k2s-bom.json'"

    # build and execute validate command
    $CMD = "$global:BinPath\cyclonedx-win-x64"
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
        ExecCmdMaster 'sudo curl --proxy http://172.19.1.1:8181 -sLO https://github.com/aquasecurity/trivy/releases/download/v0.69.1/trivy_0.69.1_Linux-64bit.tar.gz 2>&1'
        ExecCmdMaster 'sudo tar -xzf ./trivy_0.69.1_Linux-64bit.tar.gz trivy'
        ExecCmdMaster 'sudo rm ./trivy_0.69.1_Linux-64bit.tar.gz'
        ExecCmdMaster 'sudo mv ./trivy /usr/local/bin/'
        ExecCmdMaster 'sudo chmod +x /usr/local/bin/trivy'
    }

    Write-Output 'Generate bom for debian (this may take 5-15 minutes, please wait...)'
    Write-Output 'Running: trivy rootfs / --scanners license --license-full --format cyclonedx'
    Write-Output 'Note: Progress output from trivy may not be visible. The process is running in the background.'
    $startTime = Get-Date
    ExecCmdMaster -CmdToExecute 'sudo HTTPS_PROXY=http://172.19.1.1:8181 trivy rootfs / --scanners license --license-full --format cyclonedx -o kubemaster.json 2>&1' -Retries 6 -Timeout 30
    $elapsed = (Get-Date) - $startTime
    Write-Output "Debian BOM generation completed in $($elapsed.TotalMinutes.ToString('F2')) minutes"

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

    # reset proxy
    $env:GLOBAL_AGENT_HTTP_PROXY = ''
    $env:https_proxy = ''

    # dump all images
    &$bomRootDir\DumpK2sImages.ps1

    # export all addons to have all images pull
    Write-Output "Exporting addons to trigger pulling of containers under $tempDir"

    # export all available addons
    &"$global:KubernetesPath\k2s.exe" addons export -d $tempDir -o

    # cleanup temp directory
    if ( Test-Path -Path $tempDir\addons.zip) {
        Remove-Item -Path $tempDir\addons.zip -Force
    }

    Write-Output 'Containers images now available'
}

function EnsureRegistryAddon() {
    Write-Output 'Ensuring registry addon is enabled for Windows image scanning'
    
    $registryStatus = &"$global:KubernetesPath\k2s.exe" addons status registry -o json | ConvertFrom-Json
    if ($registryStatus.enabled -eq $true) {
        Write-Output '  -> Registry addon already enabled'
        $script:registryAvailable = $true
        return $false
    }

    Write-Output '  -> Enabling registry addon (timeout: 300s)...'
    $enableJob = Start-Job -ScriptBlock {
        param($k2sPath)
        & "$k2sPath\k2s.exe" addons enable registry -o 2>&1
        return $LASTEXITCODE
    } -ArgumentList $global:KubernetesPath

    $completed = $enableJob | Wait-Job -Timeout 300

    if ($null -eq $completed) {
        Write-Output '  -> WARNING: Registry addon enable timed out after 300s'
        $enableJob | Stop-Job
        $enableJob | Remove-Job -Force
        $script:registryAvailable = $false
        return $false
    }

    $jobOutput = Receive-Job -Job $enableJob
    Remove-Job -Job $enableJob -Force

    if ($LASTEXITCODE -ne 0) {
        Write-Output "  -> WARNING: Registry addon enable failed (exit code: $LASTEXITCODE)"
        Write-Output "  -> Output: $jobOutput"
        $script:registryAvailable = $false
        return $false
    }

    Start-Sleep -Seconds 10
    Write-Output '  -> Registry addon enabled successfully'
    $script:registryAvailable = $true
    return $true
}

function DisableRegistryIfNeeded($wasEnabledByScript) {
    if ($wasEnabledByScript) {
        Write-Output 'Disabling registry addon (was enabled by this script)'
        &"$global:KubernetesPath\k2s.exe" addons disable registry -o
    }
    else {
        Write-Output 'Registry addon was already enabled before script started, leaving it enabled'
    }
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
        Write-Output "  -> Image $name Id: $imageId"

        # check if image id is not empty
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
            
            # Run trivy with error handling to continue on failure
            try {
                Write-Output "  -> Running trivy scan for image $imageName"
                $trivyOutput = k2s node exec -i 172.19.1.100 -u remote -c "sudo HTTPS_PROXY=http://172.19.1.1:8181 trivy image --input $imageName.tar --scanners license --license-full --format cyclonedx -o $imageName.json 2>&1" 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Output "  -> WARNING: Trivy scan failed for image ${fullname} with exit code $LASTEXITCODE"
                    Write-Output "  -> Trivy output: $trivyOutput"
                    Write-Output "  -> Skipping this image and continuing with next..."
                    # Skip to cleanup and continue with next image
                    ExecCmdMaster "sudo rm -f $imageName.tar" -IgnoreErrors
                    ExecCmdMaster "sudo rm -f $imageName.json" -IgnoreErrors
                    continue
                }
                Write-Output "  -> Trivy scan completed successfully"
            }
            catch {
                Write-Output "  -> ERROR: Exception during trivy scan for image ${fullname}: $($_.Exception.Message)"
                Write-Output "  -> Skipping this image and continuing with next..."
                # Cleanup and continue
                ExecCmdMaster "sudo rm -f $imageName.tar" -IgnoreErrors
                ExecCmdMaster "sudo rm -f $imageName.json" -IgnoreErrors
                continue
            }
            
            # copy bom file to local folder
            $source = "$global:Remote_Master" + ":/home/remote/$imageName.json"
            try {
                Copy-FromToMaster -Source $source -Target "$bomRootDir\merge"
            }
            catch {
                Write-Output "  -> ERROR: Failed to copy BOM file for image ${fullname}: $($_.Exception.Message)"
                Write-Output "  -> Skipping this image and continuing with next..."
                ExecCmdMaster "sudo rm -f $imageName.tar" -IgnoreErrors
                ExecCmdMaster "sudo rm -f $imageName.json" -IgnoreErrors
                continue
            }

            if ($Annotate) {
                $imageSBOMJsonFile = "$bomRootDir\merge\$imageName.json"
                Write-Output "Enriching generated sbom with command 'sbomgenerator.exe -e `"$imageSBOMJsonFile`" -t `"$type`" -c `"$version`" "
                try {
                    &"$bomRootDir\sbomgenerator.exe" -e `"$imageSBOMJsonFile`" -t `"$type`" -c `"$version`"
                }
                catch {
                    Write-Output "  -> WARNING: SBOM enrichment failed for image ${fullname}: $($_.Exception.Message)"
                    Write-Output "  -> Continuing with unenriched SBOM..."
                }
            }

            # delete tar file
            ExecCmdMaster "sudo rm -f $imageName.tar"
            ExecCmdMaster "sudo rm -f $imageName.json"
        }
        else {
            Write-Output "  -> Image $name is windows image, skipping"
            $imageObject = [PSCustomObject]@{
                ImageName    = $name
                ImageType    = $type
                ImageVersion = $version
            }
            $imagesWindows += $imageObject
        }
    }

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

        # pull the image with k2s
        $imagefullname = $image + ':' + $version
        Write-Output "  -> Pulling image: $imagefullname"
        &"$global:KubernetesPath\k2s.exe" image pull $imagefullname -w

        # get image id
        $img = (&"$global:KubernetesPath\k2s.exe" image ls -A -o json | ConvertFrom-Json).containerimages | Where-Object { $_.repository -eq $image }
        if ($null -eq $img) {
            throw "Image $image not found in k2s, please use for containerd a drive with more space !"
        }

        # Special handling for windows-exporter: use registry-based scanning to avoid tar format issues
        if ($image -match 'windows-exporter') {
            if (-not $script:registryAvailable) {
                Write-Output "  -> Skipping windows-exporter scan: registry addon not available"
                continue
            }
            Write-Output "  -> Detected windows-exporter image, using registry-based scanning"
            
            # Tag and push to local registry for scanning
            $registryImage = "k2s.registry.local:30500/$imageName"
            $registryImageFull = "${registryImage}:${version}"
            Write-Output "  -> Tagging image for local registry: $registryImageFull"
            &"$global:KubernetesPath\k2s.exe" image tag -n $imagefullname -t $registryImageFull
            if ($LASTEXITCODE -ne 0) {
                Write-Output "  -> ERROR: Failed to tag image '$imagefullname' as '$registryImageFull' (exit code: $LASTEXITCODE). Skipping."
                continue
            }

            Write-Output "  -> Pushing image to local registry: $registryImageFull"
            &"$global:KubernetesPath\k2s.exe" image push -n $registryImageFull
            if ($LASTEXITCODE -ne 0) {
                Write-Output "  -> ERROR: Failed to push image '$registryImageFull' to local registry (exit code: $LASTEXITCODE). Skipping."
                &"$global:KubernetesPath\k2s.exe" image rm $registryImageFull -ErrorAction SilentlyContinue
                continue
            }

            Write-Output "  -> Creating bom for windows-exporter from registry: $imageName"
            
            # Run trivy scanning from registry with error handling
            try {
                Write-Output "  -> Running trivy scan from registry for windows-exporter"
                $trivyOutput = k2s node exec -i 172.19.1.100 -u remote -c "sudo trivy image --platform windows/amd64 --insecure localhost:30500/$imageName`:$version --scanners license --license-full --format cyclonedx -o $imageName.json 2>&1" 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Output "  -> WARNING: Trivy scan failed for windows-exporter with exit code $LASTEXITCODE"
                    Write-Output "  -> Trivy output: $trivyOutput"
                    Write-Output "  -> Skipping this image and continuing with next..."
                    &"$global:KubernetesPath\k2s.exe" image rm $registryImageFull -ErrorAction SilentlyContinue
                    DisableRegistryIfNeeded -wasEnabledByScript $script:registryEnabledByScript
                    continue
                }
                Write-Output "  -> Trivy scan completed successfully from registry"
            }
            catch {
                Write-Output "  -> ERROR: Exception during trivy scan for windows-exporter: $($_.Exception.Message)"
                Write-Output "  -> Skipping this image and continuing with next..."
                
                &"$global:KubernetesPath\k2s.exe" image rm $registryImageFull -ErrorAction SilentlyContinue
                DisableRegistryIfNeeded -wasEnabledByScript $script:registryEnabledByScript
                continue
            }

            # copy bom file to local folder
            $source = "$global:Remote_Master" + ":/home/remote/$imageName.json"
            try {
                Copy-FromToMaster -Source $source -Target "$bomRootDir\merge"
            }
            catch {
                Write-Output "  -> ERROR: Failed to copy BOM file for windows-exporter: $($_.Exception.Message)"
                Write-Output "  -> Skipping this image and continuing with next..."
                ExecCmdMaster "sudo rm -f $imageName.json" -IgnoreErrors
                &"$global:KubernetesPath\k2s.exe" image rm $registryImageFull -ErrorAction SilentlyContinue
                DisableRegistryIfNeeded -wasEnabledByScript $script:registryEnabledByScript
                continue
            }

            if ($Annotate) {
                $imageSBOMJsonFile = "$bomRootDir\merge\$imageName.json"
                Write-Output "Enriching generated sbom with command 'sbomgenerator.exe -e `"$imageSBOMJsonFile`" -t `"$type`" -c `"$version`""
                try {
                    &"$bomRootDir\sbomgenerator.exe" -e `"$imageSBOMJsonFile`" -t `"$type`" -c `"$version`"
                }
                catch {
                    Write-Output "  -> WARNING: SBOM enrichment failed for windows-exporter: $($_.Exception.Message)"
                    Write-Output "  -> Continuing with unenriched SBOM..."
                }
            }

            # Cleanup: remove JSON from VM and image from registry
            ExecCmdMaster "sudo rm -f $imageName.json" -IgnoreErrors
            Write-Output "  -> Removing image from local registry: $registryImageFull"
            &"$global:KubernetesPath\k2s.exe" image rm $registryImageFull -ErrorAction SilentlyContinue
        }
        else {
            # copy to master
            Write-Output "  -> Exporting windows image: $imageName with id: $img.imageid to $tempDir\$imageName.tar"
            &"$global:KubernetesPath\k2s.exe" image export --id $img.imageid -t "$tempDir\\$imageName.tar" --docker-archive

            # copy to master since cdxgen is not available on windows
            Write-Output "  -> Copied to kubemaster: $imageName.tar"
            &"$global:KubernetesPath\k2s.exe" node copy -i 172.19.1.100 -u remote -s "$tempDir\\$imageName.tar" -t '/home/remote'

            Write-Output "  -> Creating bom for windows image: $imageName"
            # TODO: with license it does not work yet from cdxgen point of view
            #ExecCmdMaster "sudo GLOBAL_AGENT_HTTP_PROXY=http://172.19.1.1:8181 SCAN_DEBUG_MODE=debug FETCH_LICENSE=true DEBIAN_FRONTEND=noninteractive cdxgen --required-only -t containerfile /home/remote/$imageName.tar -o $imageName.json" -IgnoreErrors -NoLog | Out-Null
            
            # Run trivy with error handling to continue on failure
            try {
                Write-Output "  -> Running trivy scan for windows image $imageName"
                $trivyOutput = k2s node exec -i 172.19.1.100 -u remote -c "sudo HTTPS_PROXY=http://172.19.1.1:8181 trivy image --input $imageName.tar --scanners license --license-full --format cyclonedx -o $imageName.json 2>&1" 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Output "  -> WARNING: Trivy scan failed for windows image ${imagefullname} with exit code $LASTEXITCODE"
                    Write-Output "  -> Trivy output: $trivyOutput"
                    Write-Output "  -> Skipping this image and continuing with next..."
                    # Cleanup and continue
                    ExecCmdMaster "sudo rm -f /home/remote/$imageName.tar" -IgnoreErrors
                    Remove-Item -Path "$tempDir\\$imageName.tar" -Force -ErrorAction SilentlyContinue
                    continue
                }
                Write-Output "  -> Trivy scan completed successfully"
            }
            catch {
                Write-Output "  -> ERROR: Exception during trivy scan for windows image ${imagefullname}: $($_.Exception.Message)"
                Write-Output "  -> Skipping this image and continuing with next..."
                # Cleanup and continue
                ExecCmdMaster "sudo rm -f /home/remote/$imageName.tar" -IgnoreErrors
                Remove-Item -Path "$tempDir\\$imageName.tar" -Force -ErrorAction SilentlyContinue
                continue
            }

            # copy bom file to local folder
            $source = "$global:Remote_Master" + ":/home/remote/$imageName.json"
            try {
                Copy-FromToMaster -Source $source -Target "$bomRootDir\merge"
            }
            catch {
                Write-Output "  -> ERROR: Failed to copy BOM file for windows image ${imagefullname}: $($_.Exception.Message)"
                Write-Output "  -> Skipping this image and continuing with next..."
                ExecCmdMaster "sudo rm /home/remote/$imageName.tar" -IgnoreErrors
                Remove-Item -Path "$tempDir\\$imageName.tar" -Force -ErrorAction SilentlyContinue
                continue
            }

            if ($Annotate) {
                $imageSBOMJsonFile = "$bomRootDir\merge\$imageName.json"
                Write-Output "Enriching generated sbom with command 'sbomgenerator.exe -e `"$imageSBOMJsonFile`" -t `"$type`" -c `"$version`""
                try {
                    &"$bomRootDir\sbomgenerator.exe" -e `"$imageSBOMJsonFile`" -t `"$type`" -c `"$version`"
                }
                catch {
                    Write-Output "  -> WARNING: SBOM enrichment failed for windows image ${imagefullname}: $($_.Exception.Message)"
                    Write-Output "  -> Continuing with unenriched SBOM..."
                }
            }

            # remove tar file
            ExecCmdMaster "sudo rm /home/remote/$imageName.tar"
            Remove-Item -Path "$tempDir\\$imageName.tar" -Force
        }
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

Write-Output 'Generating SBOM for all available addons'

$generationStopwatch = [system.diagnostics.stopwatch]::StartNew()

Write-Output '1 -> Check system state'
CheckVMState
Write-Output '2 -> Install tool trivy'
EnsureTrivy
Write-Output '3 -> Install tool cdxgen'
EnsureCdxCli
Write-Output '4 -> Remove old container files'
RemoveOldContainerFiles
Write-Output '5 -> Generate bom for directory: k2s'
GenerateBomGolang('k2s')
Write-Output '6 -> Generate bom for debian VM'
GenerateBomDebian
Write-Output '7 -> Ensure registry addon is enabled'
$script:registryAvailable = $false
$script:registryEnabledByScript = EnsureRegistryAddon
if (-not $script:registryAvailable) {
    Write-Output '  -> WARNING: Registry not available. Windows-exporter scan will be skipped.'
}
Write-Output '8 -> Load k2s images'
LoadK2sImages
Write-Output '9 -> Generate bom for containers'
GenerateBomContainers
Write-Output '10 -> Disable registry addon if enabled by script'
DisableRegistryIfNeeded -wasEnabledByScript $script:registryEnabledByScript
Write-Output '11 -> Update k2s version in static BOM'
Update-K2sStaticVersion
Write-Output '12 -> Merge bom files'
MergeBomFilesFromDirectory

Write-Output '---------------------------------------------------------------'
Write-Output " Generate bom file finished.   Total duration: $('{0:hh\:mm\:ss}' -f $generationStopwatch.Elapsed )"
Write-Output '---------------------------------------------------------------'
