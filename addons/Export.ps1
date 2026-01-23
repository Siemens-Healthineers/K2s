# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Export directory of addon')]
    [string] $ExportDir,
    [parameter(Mandatory = $false, HelpMessage = 'Export all addons')]
    [switch] $All,
    [parameter(Mandatory = $false, HelpMessage = 'Name of Addons to export')]
    [string[]] $Names,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$infraModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
$nodeModule = "$PSScriptRoot/../lib/modules/k2s/k2s.node.module/k2s.node.module.psm1"
$addonsModule = "$PSScriptRoot\addons.module.psm1"
$exportModule = "$PSScriptRoot\export.module.psm1"
$ociModule = "$PSScriptRoot\oci.module.psm1"

Import-Module $infraModule, $clusterModule, $nodeModule, $addonsModule, $exportModule, $ociModule

# Read K2s version for export metadata and file naming
$k2sVersion = Get-Content "$PSScriptRoot\..\VERSION" -Raw | ForEach-Object { $_.Trim() }

Initialize-Logging -ShowLogs:$ShowLogs

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

$setupInfo = Get-SetupInfo
if ($setupInfo.LinuxOnly -eq $true) {
    $errMsg = 'Cannot export addons in Linux-only setup' 
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code ErrCodeWrongSetupType -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$tmpExportDir = "${ExportDir}\tmp-exported-addons"
Remove-Item -Force "$tmpExportDir" -Recurse -Confirm:$False -ErrorAction SilentlyContinue
mkdir -Force "${tmpExportDir}\artifacts" | Out-Null

$ociMediaTypes = Get-OciMediaTypes

$addonManifests = @()
$allManifests = Find-AddonManifests -Directory $PSScriptRoot |`
    ForEach-Object { 
    $manifest = Get-FromYamlFile -Path $_ 
    $manifest | Add-Member -NotePropertyName 'path' -NotePropertyValue $_
    $dirPath = Split-Path -Path $_ -Parent
    $dirName = Split-Path -Path $dirPath -Leaf
    $manifest | Add-Member -NotePropertyName 'dir' -NotePropertyValue @{path = $dirPath; name = $dirName }
    $manifest
}

if ($All) {
    $addonManifests += $allManifests
}
else {    
    foreach ($name in $Names) {
        $foundManifest = $null
        $addonName = ($name -split ' ')[0]
        $implementationName = ($name -split ' ')[1]

        foreach ($manifest in $allManifests) {
            if ($manifest.metadata.name -eq $addonName) {
                $foundManifest = $manifest

                # specific implementation specified
                if ($null -ne $implementationName) {
                    $foundManifest.spec.implementations = $foundManifest.spec.implementations | Where-Object { $_.name -eq $implementationName }
                }
                break
            }
        }

        if ($null -eq $foundManifest) {
            $errMsg = "no addon with name '$addonName' found"
            if ($EncodeStructuredOutput -eq $true) {
                $err = New-Error -Severity Warning -Code ErrCodeAddonNotFound -Message $errMsg
                Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                return
            }
        
            Write-Log $errMsg -Error
            exit 1
        }

        $addonManifests += $foundManifest
    }
}

$windowsHostIpAddress = Get-ConfiguredKubeSwitchIP
$Proxy = "http://$($windowsHostIpAddress):8181"

$currentHttpProxy = $env:http_proxy
$currentHttpsProxy = $env:https_proxy

try {
    $env:http_proxy = $Proxy
    $env:https_proxy = $Proxy

    $addonExportInfo = @{addons = @() }

    foreach ($manifest in $addonManifests) {
        foreach ($implementation in $manifest.spec.implementations) {
            # there are more than one implementation
            $addonName = $manifest.metadata.name
            $dirName = $manifest.dir.name
            $dirPath = $manifest.dir.path
            if ($implementation.name -ne $addonName) {
                $addonName += " $($implementation.name)"
                $dirName += "_$($implementation.name)"
                $dirPath = Join-Path -Path $($manifest.dir.path) -ChildPath $($implementation.name)
            }

             $addonFolderName = ($addonName -split '\s+') -join '_'

             # Destination path for OCI artifact: $tmpExportDir\artifacts\ingress_nginx
             $artifactPath = Join-Path -Path $tmpExportDir -ChildPath "artifacts\$addonFolderName"

             if (-not (Test-Path $artifactPath)) {
                 New-Item -ItemType Directory -Path $artifactPath -Force | Out-Null
             }

             # Create staging directories for OCI layers
             $manifestsStaging = Join-Path $artifactPath 'manifests-staging'
             $scriptsStaging = Join-Path $artifactPath 'scripts-staging'
             $packagesStaging = Join-Path $artifactPath 'packages-staging'
             $imagesStaging = Join-Path $artifactPath 'images-staging'
             
             New-Item -ItemType Directory -Path $manifestsStaging -Force | Out-Null
             New-Item -ItemType Directory -Path $scriptsStaging -Force | Out-Null
             New-Item -ItemType Directory -Path $packagesStaging -Force | Out-Null
             New-Item -ItemType Directory -Path $imagesStaging -Force | Out-Null

             $sourceManifestsDir = Join-Path $dirPath 'manifests'
             if (Test-Path $sourceManifestsDir) {
                 Copy-Item -Path (Join-Path $sourceManifestsDir '*') -Destination $manifestsStaging -Recurse -Force -ErrorAction SilentlyContinue
             }

             @('Enable.ps1', 'Disable.ps1', 'Get-Status.ps1', 'Update.ps1', 'README.md') | ForEach-Object {
                 $scriptPath = Join-Path $dirPath $_
                 if (Test-Path $scriptPath) {
                     Copy-Item -Path $scriptPath -Destination $scriptsStaging -Force
                 }
             }
             Get-ChildItem -Path $dirPath -Filter '*.psm1' -ErrorAction SilentlyContinue | ForEach-Object {
                 Copy-Item -Path $_.FullName -Destination $scriptsStaging -Force
             }
             
             @('*.png', '*.jpg', '*.jpeg', '*.gif', '*.svg', '*.drawio', '*.drawio.png', '*.md', '*.ndjson', '*.json', '*.license') | ForEach-Object {
                 Get-ChildItem -Path $dirPath -Filter $_ -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                     if ($_.Name -ne 'README.md') {
                         $relativePath = $_.FullName.Substring($dirPath.Length + 1)
                         $targetPath = Join-Path $scriptsStaging $relativePath
                         $targetDir = Split-Path $targetPath -Parent
                         
                         if (-not (Test-Path $targetDir)) {
                             New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
                         }
                         
                         Copy-Item -Path $_.FullName -Destination $targetPath -Force
                         Write-Log "[OCI] Copying documentation asset: $relativePath"
                     }
                 }
             }

            # Handle addon.manifest.yaml
            $manifestFile = $null
            if ($implementation.name -ne $manifest.metadata.name) {
                $parentAddonFolder = Split-Path -Path $dirPath -Parent
                $manifestFile = Join-Path $parentAddonFolder "addon.manifest.yaml"
            } else {
                $manifestFile = Join-Path $dirPath "addon.manifest.yaml"
            }
            
            if ($manifestFile -and (Test-Path $manifestFile)) {
                $configManifestPath = Join-Path $artifactPath "addon.manifest.yaml"
                
                # For single implementation exports
                if (-not $All -and $Names.Count -eq 1 -and $implementation.name -ne $manifest.metadata.name) {
                    $kubeBinPath = Get-KubeBinPath
                    $yqExe = Join-Path $kubeBinPath "windowsnode\yaml\yq.exe"
                    
                    try {
                        Copy-Item -Path $manifestFile -Destination $configManifestPath -Force
                        
                        $tempFilterFile = New-TemporaryFile
                        $filterContent = ".spec.implementations |= [.[] | select(.name == `"$($implementation.name)`")]"
                        Set-Content -Path $tempFilterFile.FullName -Value $filterContent -Encoding ASCII
                        
                        & $yqExe eval --from-file $tempFilterFile --inplace $configManifestPath
                        
                        Write-Log "[OCI] Filtered manifest for single implementation: $($implementation.name)" -Console
                        Remove-Item -Path $tempFilterFile -Force -ErrorAction SilentlyContinue
                    } catch {
                        Write-Log "[OCI] Failed to filter manifest with yq.exe (Path: $yqExe), falling back to copy: $_" -Console
                        Copy-Item -Path $manifestFile -Destination $configManifestPath -Force
                    }
                } else {
                    # For all exports or single implementation addons, copy original manifest
                    Copy-Item -Path $manifestFile -Destination $configManifestPath -Force
                }
            } else {
                Write-Log "[OCI] Warning: addon.manifest.yaml not found for $addonName"
            }

            # Add version information as OCI annotations (stored in oci-manifest.json)
            Write-Log "[OCI] Preparing OCI artifact for addon $addonName" -Console
            
            Write-Log "Pulling images for addon $addonName from $dirPath" -Console

            Write-Log '---'
            $images = @()
            $linuxImages = @()
            $windowsImages = @()
            $files = Get-Childitem -recurse $dirPath | Where-Object { $_.Name -match '.*.yaml$' } | ForEach-Object { $_.Fullname }

            # check if there is a subfolder called chart for helm charts
            if (Test-Path -Path "$dirPath\manifests\chart") {
                $charts = Get-Childitem -recurse "$dirPath\manifests\chart" | Where-Object { $_.Name -match '.*.tgz$' } | ForEach-Object { $_.Fullname }
                if ($null -eq $charts -or $charts.Count -eq 0) {
                    Write-Log "No images found for addon $addonName in form of an chart"
                } else {
                    Write-Log "Found images for addon $addonName in form of an chart, count: $($charts.Count)"
                    # ensure only one entry in the list
                    $charts = $charts | Select-Object -Unique
                    foreach ($chart in $charts) {
                        # extracting yaml files from the helm chart
                        $chartFolder = "${tmpExportDir}\helm\$dirName"
                        mkdir -Force $chartFolder | Out-Null
                        # extracting yaml files from the helm chart
                        $valuesFile = "$dirPath\manifests\chart\values.yaml"
                        # extract release from chart file name by removing the .tgz extension and the version
                        # from kubernetes-dashboard-x.x.x.tgz -> kubernetes-dashboard
                        $chartNameParts = [System.IO.Path]::GetFileNameWithoutExtension($chart).Split('-')
                        $release = $chartNameParts[0..($chartNameParts.Length - 2)] -join '-'

                        if ((Test-Path -Path $valuesFile)) {
                            (Invoke-Helm -Params 'template', $release, $chart, '-f', $valuesFile, '--output-dir', $chartFolder).Output | Write-Log 
                        } else {
                            (Invoke-Helm -Params 'template', $release, $chart, '--output-dir', $chartFolder).Output | Write-Log 
                        }
                        $files += Get-Childitem -recurse $chartFolder | Where-Object { $_.Name -match '.*.yaml$' } | ForEach-Object { $_.Fullname }
                    }
                }
            }

            foreach ($file in $files) {
                if ($null -ne (Select-String -Path $file -Pattern '## exclude-from-export')) {
                    continue
                }

                $imageLines = Get-Content $file | Select-String 'image:' | Select-Object -ExpandProperty Line
                foreach ($imageLine in $imageLines) {
                    if ($imageLine.TrimStart() -match '^#') {
                        continue
                    }
                    
                    $image = (($imageLine -split 'image: ')[1] -split '#')[0]
                    $parts = $image.Split(':')
                    if ($parts.Count -gt 1) {
                        Write-Log "Image is valid $image"
                    } else {
                        Write-Log "Image is not valid $image, will skip it"
                        continue
                    }
                    if ($imageLine.Contains('#windows_image')) {
                        $windowsImages += $image
                    }
                    else {
                        $linuxImages += $image
                    }
                }
            }

            # Process addon.manifest.yaml offline_usage section for image declarations
            if ($null -ne $implementation.offline_usage) {
                $linuxPackages = $implementation.offline_usage.linux
                
                # Collect Linux-only images from additionalImages
                if ($linuxPackages.additionalImages) {
                    $linuxImages += $linuxPackages.additionalImages
                }
                
                # Extract images from referenced YAML manifest files (e.g., deployment.yaml)
                if ($linuxPackages.additionalImagesFiles) {
                    $linuxImages += Get-ImagesFromYamlFiles -YamlFiles $linuxPackages.additionalImagesFiles -BaseDirectory $dirPath
                }

                # Collect Windows-specific images from additionalImages
                $windowsPackages = $implementation.offline_usage.windows
                if ($null -ne $windowsPackages -and $windowsPackages.additionalImages) {
                    $windowsImages += $windowsPackages.additionalImages
                }
                
                # Extract Windows images from referenced YAML manifest files (e.g., daemonset.yaml)
                if ($null -ne $windowsPackages -and $windowsPackages.additionalImagesFiles) {
                    $windowsImages += Get-ImagesFromYamlFiles -YamlFiles $windowsPackages.additionalImagesFiles -BaseDirectory $dirPath
                }
            }

            $linuxImages = $linuxImages | Select-Object -Unique | Where-Object { $_ -ne '' } | ForEach-Object { $_.Trim("`"'").Trim(' ') }
            $linuxImages = Remove-VersionlessImages -Images $linuxImages
            $windowsImages = $windowsImages | Select-Object -Unique | Where-Object { $_ -ne '' } | ForEach-Object { $_.Trim("`"'").Trim(' ') }
            $windowsImages = Remove-VersionlessImages -Images $windowsImages
            $images += $linuxImages
            $images += $windowsImages
            $images = $images | Select-Object -Unique

            foreach ($image in $linuxImages) {
                Write-Log "Pulling linux image $image"
                $pull = Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -Retries 5 -CmdToExecute "sudo buildah pull $image 2>&1"
                Write-Log $pull.Output
                if (!$pull.Success) {
                    $errMsg = "Pulling linux image $image failed"
                    if ($EncodeStructuredOutput -eq $true) {
                        $err = New-Error -Severity Warning -Code ErrCodeAddonNotFound -Message $errMsg
                        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                        return
                    }
                
                    Write-Log $errMsg -Error
                    exit 1
                }
            }

            foreach ($image in $windowsImages) {
                Write-Log "Pulling windows image $image"
                $kubeBinPath = Get-KubeBinPath
                &$(Get-NerdctlExe) -n 'k8s.io' pull $image --all-platforms 2>&1 | Out-Null
                &$(Get-CrictlExe) --config $kubeBinPath\crictl.yaml pull $image
                if (!$?) {
                    $errMsg = "Pulling linux image $image failed"
                    if ($EncodeStructuredOutput -eq $true) {
                        $err = New-Error -Severity Warning -Code ErrCodeAddonNotFound -Message $errMsg
                        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                        return
                    }
                    
                    Write-Log $errMsg -Error
                    exit 1
                }
            }

            if ($images.Count -gt 0) {
                Write-Log '---'
                Write-Log "Images pulled successfully for addon $addonName"
                Write-Log '---'

                $linuxContainerImages = Get-ContainerImagesOnLinuxNode -IncludeK8sImages $false
                $windowsContainerImages = Get-ContainerImagesOnWindowsNode -IncludeK8sImages $false

                Write-Log "[OCI] Exporting images for addon $addonName to OCI layers" -Console

                $linuxImageTars = @()
                $windowsImageTars = @()
                $count = 0
                
                foreach ($image in $images) {
                    Write-Log $image
                    $imageNameWithoutTag = ($image -split ':')[0]
                    $imageTag = ($image -split ':')[1]
                    $linuxImageToExportArray = @($linuxContainerImages | Where-Object { $_.Repository -match ".*${imageNameWithoutTag}$" -and $_.Tag -eq $imageTag })
                    $windowsImageToExportArray = @($windowsContainerImages | Where-Object { $_.Repository -match ".*${imageNameWithoutTag}$" -and $_.Tag -eq $imageTag })
                    $exportImageScript = "$PSScriptRoot\..\lib\scripts\k2s\image\Export-Image.ps1"
                    
                    if ($linuxImageToExportArray -and $linuxImageToExportArray.Count -gt 0) {
                        $imageToExport = $linuxImageToExportArray[0]
                        $linuxImageTarPath = "${imagesStaging}\linux_${count}.tar"
                        &$exportImageScript -Id $imageToExport.ImageId -ExportPath $linuxImageTarPath -ShowLogs:$ShowLogs

                        if (!$?) {
                            $errMsg = "Image $imageNameWithoutTag could not be exported."
                            if ($EncodeStructuredOutput -eq $true) {
                                $err = New-Error -Code 'image-not-exported' -Message $errMsg
                                Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                                return
                            }
                        
                            Write-Log $errMsg -Error
                            exit 1
                        }
                        $linuxImageTars += $linuxImageTarPath
                        $count += 1
                    }

                    if ($windowsImageToExportArray -and $windowsImageToExportArray.Count -gt 0) {
                        $imageToExport = $windowsImageToExportArray[0]
                        $windowsImageTarPath = "${imagesStaging}\windows_${count}.tar"
                        &$exportImageScript -Id $imageToExport.ImageId -ExportPath $windowsImageTarPath -ShowLogs:$ShowLogs

                        if (!$?) {
                            $errMsg = "Image $imageNameWithoutTag could not be exported!"
                            if ($EncodeStructuredOutput -eq $true) {
                                $err = New-Error -Code 'image-not-exported' -Message $errMsg
                                Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                                return
                            }
                        
                            Write-Log $errMsg -Error
                            exit 1
                        }
                        $windowsImageTars += $windowsImageTarPath
                        $count += 1
                    }
                }
                
                # Consolidate Linux images into single tar layer
                if ($linuxImageTars.Count -gt 0) {
                    Write-Log "[OCI] Consolidating $($linuxImageTars.Count) Linux images into single layer"
                    $linuxImagesLayerPath = Join-Path $artifactPath 'images-linux.tar'
                    
                    # creating a consolidated tar (even for single image) to maintain consistent structure
                    New-TarArchive -SourceFiles $linuxImageTars -DestinationPath $linuxImagesLayerPath -WorkingDirectory $imagesStaging
                }
                
                # Consolidate Windows images into single tar layer
                if ($windowsImageTars.Count -gt 0) {
                    Write-Log "[OCI] Consolidating $($windowsImageTars.Count) Windows images into single layer"
                    $windowsImagesLayerPath = Join-Path $artifactPath 'images-windows.tar'
                    
                    # creating a consolidated tar (even for single image) to maintain consistent structure
                    New-TarArchive -SourceFiles $windowsImageTars -DestinationPath $windowsImagesLayerPath -WorkingDirectory $imagesStaging
                }
            }
            else {
                Write-Log "No images found for addon $addonName"
            }

            if ($null -ne $implementation.offline_usage) {
                Write-Log '---'
                Write-Log "[OCI] Downloading packages for addon $addonName" -Console
                $linuxPackages = $implementation.offline_usage.linux

                # adding repos for debian packages download
                $repos = $linuxPackages.repos
                if ($repos) {
                    Write-Log 'Adding repos for debian packages download'
                    foreach ($repo in $repos) {
                        $repoWithReplacedHttpProxyPlaceHolder = $repo.Replace('__LOCAL_HTTP_PROXY__', "$(Get-ConfiguredKubeSwitchIP):8181")
                        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "$repoWithReplacedHttpProxyPlaceHolder").Output | Write-Log
                    }

                    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo apt-get update > /dev/null 2>&1').Output | Write-Log
                }

                # download debian packages
                $debianPackages = $linuxPackages.deb
                if ($debianPackages) {
                    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo apt-get clean > /dev/null 2>&1').Output | Write-Log
                    foreach ($package in $debianPackages) {
                        if (!(Get-DebianPackageAvailableOffline -addon $manifest.metadata.name -implementation $implementation.name -package $package)) {
                            Write-Log "Downloading debian package `"$package`" with dependencies"
                            (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo DEBIAN_FRONTEND=noninteractive apt-get --download-only reinstall -y $package > /dev/null 2>&1").Output | Write-Log
                            (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "mkdir -p .$dirName/${package}").Output | Write-Log
                            (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo cp /var/cache/apt/archives/*.deb .$dirName/${package}").Output | Write-Log
                            (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo apt-get clean > /dev/null 2>&1').Output | Write-Log
                        }
                    }

                    $targetDebianPkgDir = "${packagesStaging}\debianpackages"

                    mkdir -Force $targetDebianPkgDir | Out-Null
                    Copy-FromControlPlaneViaSSHKey -Source ".$dirName/*" -Target $targetDebianPkgDir
                }

                # download linux packages via curl
                $linuxCurlPackages = $linuxPackages.curl
                if ($linuxCurlPackages) {
                    $targetLinuxPkgDir = "${packagesStaging}\linuxpackages"
                    mkdir -Force $targetLinuxPkgDir | Out-Null

                    foreach ($package in $linuxCurlPackages) {
                        $filename = ([uri]$package.url).Segments[-1]

                        Invoke-DownloadFile "$targetLinuxPkgDir\${filename}" $package.url $true -ProxyToUse $Proxy
                    }
                }

                # download windows packages via curl
                $windowsPackages = $implementation.offline_usage.windows
                $windowsCurlPackages = $windowsPackages.curl
                if ($windowsCurlPackages) {
                    $targetWinPkgDir = "${packagesStaging}\windowspackages"
                    mkdir -Force $targetWinPkgDir | Out-Null
                    foreach ($package in $windowsCurlPackages) {
                        $filename = ([uri]$package.url).Segments[-1]

                        Invoke-DownloadFile "$targetWinPkgDir\${filename}" $package.url $true -ProxyToUse $Proxy
                    }
                }
            }

            Write-Log "[OCI] Creating OCI artifact layers for $addonName" -Console
            
            $ociLayers = @{}
            
            # Layer 1: Manifests
            if ((Get-ChildItem $manifestsStaging -ErrorAction SilentlyContinue).Count -gt 0) {
                $manifestsTarPath = Join-Path $artifactPath 'manifests.tar.gz'
                if (New-TarGzArchive -SourcePath $manifestsStaging -DestinationPath $manifestsTarPath -ArchiveContents) {
                    $ociLayers['manifests.tar.gz'] = $ociMediaTypes.Manifests
                    Write-Log "[OCI] Created manifests layer"
                }
            }
            
            # Layer 2: Helm Charts (if chart subfolder exists)
            $chartsDir = Join-Path $manifestsStaging 'chart'
            if (Test-Path $chartsDir) {
                $chartsTarPath = Join-Path $artifactPath 'charts.tar.gz'
                if (New-TarGzArchive -SourcePath $chartsDir -DestinationPath $chartsTarPath -ArchiveContents) {
                    $ociLayers['charts.tar.gz'] = $ociMediaTypes.Charts
                    Write-Log "[OCI] Created charts layer"
                }
            }
            
            # Layer 3: Scripts
            if ((Get-ChildItem $scriptsStaging -ErrorAction SilentlyContinue).Count -gt 0) {
                $scriptsTarPath = Join-Path $artifactPath 'scripts.tar.gz'
                if (New-TarGzArchive -SourcePath $scriptsStaging -DestinationPath $scriptsTarPath -ArchiveContents) {
                    $ociLayers['scripts.tar.gz'] = $ociMediaTypes.Scripts
                    Write-Log "[OCI] Created scripts layer"
                }
            }
            
            # Layer 4: Linux Images (already created above if present)
            $linuxImagesLayer = Join-Path $artifactPath 'images-linux.tar'
            if (Test-Path $linuxImagesLayer) {
                $ociLayers['images-linux.tar'] = $ociMediaTypes.ImagesLinux
            }
            
            # Layer 5: Windows Images (already created above if present)
            $windowsImagesLayer = Join-Path $artifactPath 'images-windows.tar'
            if (Test-Path $windowsImagesLayer) {
                $ociLayers['images-windows.tar'] = $ociMediaTypes.ImagesWindows
            }
            
            # Layer 6: Packages
            if ((Get-ChildItem $packagesStaging -Recurse -ErrorAction SilentlyContinue).Count -gt 0) {
                $packagesTarPath = Join-Path $artifactPath 'packages.tar.gz'
                if (New-TarGzArchive -SourcePath $packagesStaging -DestinationPath $packagesTarPath -ArchiveContents) {
                    $ociLayers['packages.tar.gz'] = $ociMediaTypes.Packages
                    Write-Log "[OCI] Created packages layer"
                }
            }
            
            $addonVersion = if ($implementation.version) { $implementation.version } else { "1.0.0" }
            $ociManifest = @{
                schemaVersion = 2
                mediaType = 'application/vnd.oci.image.manifest.v1+json'
                artifactType = 'application/vnd.k2s.addon.v1'
                config = @{
                    mediaType = $ociMediaTypes.Config
                    size = if (Test-Path (Join-Path $artifactPath 'addon.manifest.yaml')) { (Get-Item (Join-Path $artifactPath 'addon.manifest.yaml')).Length } else { 0 }
                    digest = ''
                }
                layers = @()
                annotations = @{
                    'org.opencontainers.image.title' = $manifest.metadata.name
                    'org.opencontainers.image.version' = $addonVersion
                    'vnd.k2s.addon.name' = $manifest.metadata.name
                    'vnd.k2s.addon.implementation' = $implementation.name
                    'vnd.k2s.version' = $k2sVersion
                    'vnd.k2s.export.date' = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssZ')
                    'vnd.k2s.export.type' = if ($All) { 'all' } else { 'specific' }
                }
            }
            
            foreach ($layer in $ociLayers.GetEnumerator()) {
                $layerPath = Join-Path $artifactPath $layer.Key
                if (Test-Path $layerPath) {
                    $layerHash = Get-FileHash -Path $layerPath -Algorithm SHA256
                    $ociManifest.layers += @{
                        mediaType = $layer.Value
                        size = (Get-Item $layerPath).Length
                        digest = "sha256:$($layerHash.Hash.ToLower())"
                        annotations = @{
                            'org.opencontainers.image.title' = $layer.Key
                        }
                    }
                }
            }
            
            $ociManifest | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $artifactPath 'oci-manifest.json') -Force
            
            Remove-Item -Path $manifestsStaging -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $scriptsStaging -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $packagesStaging -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $imagesStaging -Recurse -Force -ErrorAction SilentlyContinue

            $addonExportInfo.addons += @{
                name = $addonName;
                dirName = $addonFolderName;
                implementation = $implementation.name;
                version = $addonVersion;
                offline_usage = $implementation.offline_usage;
                ociLayers = $ociLayers.Keys
                artifactPath = $artifactPath
            }

            Write-Log '---' -Console    
        }    
    }

    $addonExportInfo.k2sVersion = $k2sVersion
    $addonExportInfo.exportType = if ($All) { "all" } else { "specific" }
    $addonExportInfo.artifactFormat = 'oci'
    
    # Create index manifest for multi-addon exports
    $indexManifest = @{
        schemaVersion = 2
        mediaType = 'application/vnd.oci.image.index.v1+json'
        manifests = @()
        annotations = @{
            'vnd.k2s.version' = $k2sVersion
            'vnd.k2s.export.date' = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssZ')
            'vnd.k2s.export.type' = if ($All) { 'all' } else { 'specific' }
            'vnd.k2s.addon.count' = $addonExportInfo.addons.Count
        }
    }
    
    foreach ($addon in $addonExportInfo.addons) {
        $addonManifestPath = Join-Path $addon.artifactPath 'oci-manifest.json'
        if (Test-Path $addonManifestPath) {
            $addonOciManifest = Get-Content $addonManifestPath | ConvertFrom-Json
            $indexManifest.manifests += @{
                mediaType = 'application/vnd.oci.image.manifest.v1+json'
                artifactType = 'application/vnd.k2s.addon.v1'
                annotations = @{
                    'vnd.k2s.addon.name' = $addon.name
                    'vnd.k2s.addon.implementation' = $addon.implementation
                    'vnd.k2s.addon.version' = $addon.version
                }
            }
        }
    }
    
    $indexManifest | ConvertTo-Json -Depth 10 | Set-Content -Path "${tmpExportDir}\artifacts\index.json" -Force
    $addonExportInfo | ConvertTo-Json -Depth 100 | Set-Content -Path "${tmpExportDir}\artifacts\addons.json" -Force
}
finally {
    $env:http_proxy = $currentHttpProxy
    $env:https_proxy = $currentHttpsProxy
}

# Generate versioned filename according to pattern: K2s-{version}-addons-{addon-names}
$exportedAddonNames = if ($All) {
    "all"
} else {
    ($addonExportInfo.addons | ForEach-Object { 
        ($_.name -replace '\s+', '-').ToLower()
    }) -join '-'
}

# Option 1: Push to OCI registry if specified
if ($Registry) {
    Write-Log "[OCI] Pushing artifacts to registry: $Registry" -Console
    
    foreach ($addon in $addonExportInfo.addons) {
        $repoName = "k2s-addons/$($addon.dirName)"
        $tag = $addon.version
        
        try {
            $configFile = Join-Path $addon.artifactPath 'addon.manifest.yaml'
            $layers = @{}
            
            # Add all layer files with their media types
            foreach ($layerName in $addon.ociLayers) {
                $layerPath = Join-Path $addon.artifactPath $layerName
                if (Test-Path $layerPath) {
                    $mediaType = $ociMediaTypes[$layerName -replace '\.tar.*$', '' -replace '-', '' -replace 'images', 'Images']
                    if (-not $mediaType) {
                        # Fallback media type lookup
                        switch -Wildcard ($layerName) {
                            'manifests*' { $mediaType = $ociMediaTypes.Manifests }
                            'charts*' { $mediaType = $ociMediaTypes.Charts }
                            'scripts*' { $mediaType = $ociMediaTypes.Scripts }
                            'images-linux*' { $mediaType = $ociMediaTypes.ImagesLinux }
                            'images-windows*' { $mediaType = $ociMediaTypes.ImagesWindows }
                            'packages*' { $mediaType = $ociMediaTypes.Packages }
                        }
                    }
                    $layers[$layerPath] = $mediaType
                }
            }
            
            Push-OciArtifact `
                -Registry $Registry `
                -Repository $repoName `
                -Tag $tag `
                -ConfigFile $configFile `
                -Layers $layers `
                -WorkingDirectory $addon.artifactPath `
                -Insecure:$Insecure `
                -PlainHttp:$PlainHttp
            
            Write-Log "[OCI] Pushed $($addon.name) to $Registry/$repoName`:$tag" -Console
        }
        catch {
            Write-Log "[OCI] Failed to push $($addon.name) to registry: $_" -Error
        }
    }
}

# Option 2: Create local tar archive (OCI layout)
$versionedFileName = "K2s-${k2sVersion}-addons-${exportedAddonNames}.oci.tar"
$finalExportPath = Join-Path $ExportDir $versionedFileName

Remove-Item -Force $finalExportPath -ErrorAction SilentlyContinue

# Create OCI-layout tar archive
$currentLocation = Get-Location
try {
    Set-Location "${tmpExportDir}"
    $tarResult = & tar -cvf $finalExportPath "artifacts" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "[OCI] Warning: tar creation returned: $tarResult"
    }
}
finally {
    Set-Location $currentLocation
}

Remove-Item -Force "$tmpExportDir" -Recurse -Confirm:$False -ErrorAction SilentlyContinue
Write-Log '---'
Write-Log "[OCI] Addons exported successfully as OCI artifact to $finalExportPath" -Console
Write-Log "[OCI] Artifact structure:" -Console
Write-Log "  Config:  addon.manifest.yaml (application/vnd.k2s.addon.config.v1+yaml)" -Console
Write-Log "  Layer 1: manifests.tar.gz    (application/vnd.k2s.addon.manifests.v1.tar+gzip)" -Console
Write-Log "  Layer 2: charts.tar.gz       (application/vnd.cncf.helm.chart.content.v1.tar+gzip) [if helm-based]" -Console
Write-Log "  Layer 3: scripts.tar.gz      (application/vnd.k2s.addon.scripts.v1.tar+gzip)" -Console
Write-Log "  Layer 4: images-linux.tar    (application/vnd.oci.image.layer.v1.tar)" -Console
Write-Log "  Layer 5: images-windows.tar  (application/vnd.oci.image.layer.v1.tar+windows)" -Console
Write-Log "  Layer 6: packages.tar.gz     (application/vnd.k2s.addon.packages.v1.tar+gzip)" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}