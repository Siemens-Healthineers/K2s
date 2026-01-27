# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
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

Import-Module $infraModule, $clusterModule, $nodeModule, $addonsModule, $exportModule

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
mkdir -Force "${tmpExportDir}\addons" | Out-Null

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

            # Convert addon name like "ingress nginx" to "ingress_nginx"
             $addonFolderName = ($addonName -split '\s+') -join '_'

             # Destination path: $tmpExportDir\addons\ingress_nginx
             $destinationPath = Join-Path -Path $tmpExportDir -ChildPath "addons\$addonFolderName"

             # Ensure destination directory exists
             if (-not (Test-Path $destinationPath)) {
                 New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
             }

             # Copy only the contents of $dirPath — not the folder itself
             Copy-Item -Path (Join-Path $dirPath '*') -Destination $destinationPath -Recurse -Force

            # Handle addon.manifest.yaml
            $parentAddonFolder = Split-Path -Path $dirPath -Parent
            $manifestFile = Join-Path $parentAddonFolder "addon.manifest.yaml"
            if (Test-Path $manifestFile) {
                $copiedManifestPath = Join-Path $destinationPath "addon.manifest.yaml"
                
                # For single implementation exports
                if (-not $All -and $Names.Count -eq 1 -and $implementation.name -ne $manifest.metadata.name) {
                    $kubeBinPath = Get-KubeBinPath
                    $yqExe = Join-Path $kubeBinPath "windowsnode\yaml\yq.exe"
                    
                    try {
                        Copy-Item -Path $manifestFile -Destination $copiedManifestPath -Force
                        
                        $tempFilterFile = New-TemporaryFile
                        $filterContent = ".spec.implementations |= [.[] | select(.name == `"$($implementation.name)`")]"
                        Set-Content -Path $tempFilterFile.FullName -Value $filterContent -Encoding ASCII
                        
                        & $yqExe eval --from-file $tempFilterFile --inplace $copiedManifestPath
                        
                        Write-Log "Filtered manifest for single implementation: $($implementation.name)" -Console
                        Remove-Item -Path $tempFilterFile -Force -ErrorAction SilentlyContinue
                    } catch {
                        Write-Log "Failed to filter manifest with yq.exe (Path: $yqExe), falling back to copy: $_" -Console
                        Copy-Item -Path $manifestFile -Destination $copiedManifestPath -Force
                    }
                } else {
                    # For all exports or single implementation addons, copy original manifest
                    Copy-Item -Path $manifestFile -Destination $copiedManifestPath -Force
                }
            }

            # Add version information file for CD solutions
            $versionInfoPath = Join-Path $destinationPath "version.info"
            @{
                addonName = $manifest.metadata.name
                implementationName = $implementation.name
                k2sVersion = $k2sVersion
                exportDate = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
                exportType = if ($All) { "all" } else { "specific" }
                description = if ($manifest.metadata.description) { $manifest.metadata.description } else { "" }
            } | ConvertTo-Json -Depth 10 | Set-Content -Path $versionInfoPath -Force
            
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
                        # check if value file exists
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
                    # Skip commented lines
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

            Write-Log "[DEBUG] === IMAGE LISTS AFTER PROCESSING ==="
            Write-Log "[DEBUG] Linux images to pull ($($linuxImages.Count)):"
            foreach ($img in $linuxImages) { Write-Log "[DEBUG]   - $img" }
            Write-Log "[DEBUG] Windows images to pull ($($windowsImages.Count)):"
            foreach ($img in $windowsImages) { Write-Log "[DEBUG]   - $img" }
            Write-Log "[DEBUG] Total unique images ($($images.Count)):"
            foreach ($img in $images) { Write-Log "[DEBUG]   - $img" }

            mkdir -Force "${tmpExportDir}\addons\$dirName" | Out-Null

            Write-Log "[DEBUG] === PULLING LINUX IMAGES ==="
            foreach ($image in $linuxImages) {
                Write-Log "Pulling linux image $image"
                $pull = Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -Retries 5 -CmdToExecute "sudo buildah pull $image 2>&1"
                Write-Log "[DEBUG] Pull result for $image : Success=$($pull.Success) Output='$($pull.Output)'"
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

                Write-Log "Exporting images for addon $addonName" -Console
                Write-Log "[DEBUG] Found $($linuxContainerImages.Count) linux container images, $($windowsContainerImages.Count) windows container images"
                foreach ($img in $linuxContainerImages) {
                    Write-Log "[DEBUG] Linux image: Repository='$($img.Repository)' Tag='$($img.Tag)' ImageId='$($img.ImageId)'"
                }

                $count = 0
                foreach ($image in $images) {
                    Write-Log $image
                    $imageNameWithoutTag = ($image -split ':')[0]
                    $imageTag = ($image -split ':')[1]
                    Write-Log "[DEBUG] Looking for: imageNameWithoutTag='$imageNameWithoutTag' imageTag='$imageTag'"
                    Write-Log "[DEBUG] Regex pattern: '.*${imageNameWithoutTag}$'"
                    
                    # Test regex matching manually for debugging
                    foreach ($testImg in $linuxContainerImages) {
                        $repoMatch = $testImg.Repository -match ".*${imageNameWithoutTag}$"
                        $tagMatch = $testImg.Tag -eq $imageTag
                        if ($repoMatch -or $tagMatch) {
                            Write-Log "[DEBUG] Testing against: Repository='$($testImg.Repository)' Tag='$($testImg.Tag)' -> RepoMatch=$repoMatch TagMatch=$tagMatch"
                        }
                    }
                    
                    $linuxImageToExportArray = @($linuxContainerImages | Where-Object { $_.Repository -match ".*${imageNameWithoutTag}$" -and $_.Tag -eq $imageTag })
                    $windowsImageToExportArray = @($windowsContainerImages | Where-Object { $_.Repository -match ".*${imageNameWithoutTag}$" -and $_.Tag -eq $imageTag })
                    Write-Log "[DEBUG] Matched linux images: $($linuxImageToExportArray.Count), windows images: $($windowsImageToExportArray.Count)"
                    
                    if ($linuxImageToExportArray.Count -eq 0 -and $windowsImageToExportArray.Count -eq 0) {
                        Write-Log "[DEBUG] WARNING: No matching images found for '$image' - image will NOT be exported!"
                    }
                    $exportImageScript = "$PSScriptRoot\..\lib\scripts\k2s\image\Export-Image.ps1"
                    
                    if ($linuxImageToExportArray -and $linuxImageToExportArray.Count -gt 0) {
                        $imageToExport = $linuxImageToExportArray[0]
                        &$exportImageScript -Id $imageToExport.ImageId -ExportPath "${tmpExportDir}\addons\$dirName\${count}.tar" -ShowLogs:$ShowLogs

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

                        $count += 1
                    }

                    if ($windowsImageToExportArray -and $windowsImageToExportArray.Count -gt 0) {
                        $imageToExport = $windowsImageToExportArray[0]
                        &$exportImageScript -Id $imageToExport.ImageId -ExportPath "${tmpExportDir}\addons\$dirName\${count}_win.tar" -ShowLogs:$ShowLogs

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

                        $count += 1
                    }
                }
            }
            else {
                Write-Log "No images found for addon $addonName"
            }

            if ($null -ne $implementation.offline_usage) {
                Write-Log '---'
                Write-Log "Downloading packages for addon $addonName" -Console
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

                    $targetDebianPkgDir = "${tmpExportDir}\addons\$dirName\debianpackages"

                    mkdir -Force $targetDebianPkgDir | Out-Null
                    Copy-FromControlPlaneViaSSHKey -Source ".$dirName/*" -Target $targetDebianPkgDir
                }

                # download linux packages via curl
                $linuxCurlPackages = $linuxPackages.curl
                if ($linuxCurlPackages) {
                    $targetLinuxPkgDir = "${tmpExportDir}\addons\$dirName\linuxpackages"
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
                    $targetWinPkgDir = "${tmpExportDir}\addons\$dirName\windowspackages"
                    mkdir -Force $targetWinPkgDir | Out-Null
                    foreach ($package in $windowsCurlPackages) {
                        $filename = ([uri]$package.url).Segments[-1]

                        Invoke-DownloadFile "$targetWinPkgDir\${filename}" $package.url $true -ProxyToUse $Proxy
                    }
                }
            }

            $addonExportInfo.addons += @{
                name = $addonName;
                dirName = $dirName;
                implementation = $implementation.name;
                version = if ($implementation.version) { $implementation.version } else { "1.0.0" };
                offline_usage = $implementation.offline_usage
            }

            Write-Log '---' -Console    
        }    
    }

    $addonExportInfo.k2sVersion = $k2sVersion
    $addonExportInfo.exportType = if ($All) { "all" } else { "specific" }
    
    $addonExportInfo | ConvertTo-Json -Depth 100 | Set-Content -Path "${tmpExportDir}\addons\addons.json" -Force
    
    $versionInfo = @{
        k2sVersion = $k2sVersion
        exportType = $addonExportInfo.exportType
        addonCount = $addonExportInfo.addons.Count
    }
    $versionInfo | ConvertTo-Json -Depth 10 | Set-Content -Path "${tmpExportDir}\addons\version.json" -Force
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
$versionedFileName = "K2s-${k2sVersion}-addons-${exportedAddonNames}.zip"
$finalExportPath = Join-Path $ExportDir $versionedFileName

Remove-Item -Force $finalExportPath -ErrorAction SilentlyContinue
Compress-Archive -Path "${tmpExportDir}\addons" -DestinationPath $finalExportPath -CompressionLevel Optimal -Force
Remove-Item -Force "$tmpExportDir" -Recurse -Confirm:$False -ErrorAction SilentlyContinue
Write-Log '---'
Write-Log "Addons exported successfully to $finalExportPath" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}