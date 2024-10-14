# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy,
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

        foreach ($manifest in $allManifests) {
            if ($manifest.metadata.name -eq $name) {
                $foundManifest = $manifest
                break
            }
        }

        if ($null -eq $foundManifest) {
            $errMsg = "no addon with name '$name' found"
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

$currentHttpProxy = $env:http_proxy
$currentHttpsProxy = $env:https_proxy

try {
    $env:http_proxy = $Proxy
    $env:https_proxy = $Proxy

    foreach ($manifest in $addonManifests) {
        Write-Log "Pulling images for addon $($manifest.metadata.name)" -Console
        Write-Log '---'
        $images = @()
        $linuxImages = @()
        $windowsImages = @()
        $files = Get-Childitem -recurse $manifest.dir.path | Where-Object { $_.Name -match '.*.yaml$' } | ForEach-Object { $_.Fullname }

        foreach ($file in $files) {
            if ($null -ne (Select-String -Path $file -Pattern '## exclude-from-export')) {
                continue
            }

            $imageLines = Get-Content $file | Select-String 'image:' | Select-Object -ExpandProperty Line
            foreach ($imageLine in $imageLines) {
                $image = (($imageLine -split 'image: ')[1] -split '#')[0]
                if ($imageLine.Contains('#windows_image')) {
                    $windowsImages += $image
                }
                else {
                    $linuxImages += $image
                }
            }
        }

        if ($null -ne $manifest.spec.offline_usage) {
            $linuxPackages = $manifest.spec.offline_usage.linux
            $additionImages = $linuxPackages.additionalImages
            $linuxImages += $additionImages
        }

        $linuxImages = $linuxImages | Select-Object -Unique | Where-Object { $_ -ne '' } | ForEach-Object { $_.Trim("`"'").Trim(' ') }
        $windowsImages = $windowsImages | Select-Object -Unique | Where-Object { $_ -ne '' } | ForEach-Object { $_.Trim("`"'").Trim(' ') }
        $images += $linuxImages
        $images += $windowsImages

        mkdir -Force "${tmpExportDir}\addons\$($manifest.dir.name)" | Out-Null

        foreach ($image in $linuxImages) {
            Write-Log "Pulling linux image $image"
            (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -Retries 5 -CmdToExecute "sudo buildah pull $image 2>&1").Output | Write-Log
        }

        foreach ($image in $windowsImages) {
            Write-Log "Pulling windows image $image"
            if ($setupInfo.Name -eq 'MultiVMK8s') {
                $session = Open-DefaultWinVMRemoteSessionViaSSHKey
                Invoke-Command -Session $session {
                    Set-Location "$env:SystemDrive\k"
                    Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

                    Import-Module "$env:SystemDrive\k\addons\export.module.psm1"

                    &$(Get-NerdctlExe) -n 'k8s.io' pull $using:image --all-platforms 2>&1 | Out-Null
                    &$(Get-CrictlExe) pull $using:image
                }
            }
            else {
                &$(Get-NerdctlExe) -n 'k8s.io' pull $image --all-platforms 2>&1 | Out-Null
                &$(Get-CrictlExe) pull $image
            }
        }

        if ($images.Count -gt 0) {
            Write-Log '---'
            Write-Log "Images pulled successfully for addon $($manifest.metadata.name)"
            Write-Log '---'

            $linuxContainerImages = Get-ContainerImagesOnLinuxNode -IncludeK8sImages $false
            $windowsContainerImages = Get-ContainerImagesOnWindowsNode -IncludeK8sImages $false

            Write-Log "Exporting images for addon $($manifest.metadata.name)" -Console

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
                    &$exportImageScript -Id $imageToExport.ImageId -ExportPath "${tmpExportDir}\addons\$($manifest.dir.name)\${count}.tar" -ShowLogs:$ShowLogs

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
                    &$exportImageScript -Id $imageToExport.ImageId -ExportPath "${tmpExportDir}\addons\$($manifest.dir.name)\${count}_win.tar" -ShowLogs:$ShowLogs

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
            Write-Log "No images found for addon $($manifest.metadata.name)"
        }

        if ($null -ne $manifest.spec.offline_usage) {
            Write-Log '---'
            Write-Log "Downloading packages for addon $($manifest.metadata.name)" -Console
            $linuxPackages = $manifest.spec.offline_usage.linux

            # adding repos for debian packages download
            $repos = $linuxPackages.repos
            if ($repos) {
                Write-Log 'Adding repos for debian packages download'
                foreach ($repo in $repos) {
                    if ($setupInfo.Name -ne 'MultiVMK8s') {
                        $repoWithReplacedHttpProxyPlaceHolder = $repo.Replace('__LOCAL_HTTP_PROXY__', "$(Get-ConfiguredKubeSwitchIP):8181")
                    }
                    else {
                        $repoWithReplacedHttpProxyPlaceHolder = $repo.Replace('__LOCAL_HTTP_PROXY__', "''")
                    }
                    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "$repoWithReplacedHttpProxyPlaceHolder").Output | Write-Log
                }

                (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo apt-get update > /dev/null 2>&1').Output | Write-Log
            }

            # download debian packages
            $debianPackages = $linuxPackages.deb
            if ($debianPackages) {
                (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo apt-get clean > /dev/null 2>&1').Output | Write-Log
                foreach ($package in $debianPackages) {
                    if (!(Get-DebianPackageAvailableOffline -addon $manifest.dir.name -package $package)) {
                        Write-Log "Downloading debian package `"$package`" with dependencies"
                        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo DEBIAN_FRONTEND=noninteractive apt-get --download-only reinstall -y $package > /dev/null 2>&1").Output | Write-Log
                        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "mkdir -p .$($manifest.dir.name)/${package}").Output | Write-Log
                        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo cp /var/cache/apt/archives/*.deb .$($manifest.dir.name)/${package}").Output | Write-Log
                        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo apt-get clean > /dev/null 2>&1').Output | Write-Log
                    }
                }

                $targetDebianPkgDir = "${tmpExportDir}\addons\$($manifest.dir.name)\debianpackages"

                mkdir -Force $targetDebianPkgDir | Out-Null
                Copy-FromControlPlaneViaSSHKey -Source ".$($manifest.dir.name)/*" -Target $targetDebianPkgDir
            }

            # download linux packages via curl
            $linuxCurlPackages = $linuxPackages.curl
            if ($linuxCurlPackages) {
                $targetLinuxPkgDir = "${tmpExportDir}\addons\$($manifest.dir.name)\linuxpackages"
                mkdir -Force $targetLinuxPkgDir | Out-Null

                foreach ($package in $linuxCurlPackages) {
                    $filename = ([uri]$package.url).Segments[-1]

                    Invoke-DownloadFile "$targetLinuxPkgDir\${filename}" $package.url $true -ProxyToUse $Proxy
                }
            }

            # download windows packages via curl
            $windowsPackages = $manifest.spec.offline_usage.windows
            $windowsCurlPackages = $windowsPackages.curl
            if ($windowsCurlPackages) {
                $targetWinPkgDir = "${tmpExportDir}\addons\$($manifest.dir.name)\windowspackages"
                mkdir -Force $targetWinPkgDir | Out-Null
                foreach ($package in $windowsCurlPackages) {
                    $filename = ([uri]$package.url).Segments[-1]

                    Invoke-DownloadFile "$targetWinPkgDir\${filename}" $package.url $true -ProxyToUse $Proxy
                }
            }
        }

        Write-Log '---' -Console        
    }

    $addonExportInfo = @{addons = @() }
    $addonManifests | ForEach-Object { $addonExportInfo.addons += @{name = $_.metadata.name; dirName = $_.dir.name; offline_usage = $_.spec.offline_usage } } 
    $addonExportInfo | ConvertTo-Json -Depth 100 | Set-Content -Path "${tmpExportDir}\addons\addons.json" -Force
}
finally {
    $env:http_proxy = $currentHttpProxy
    $env:https_proxy = $currentHttpsProxy
}

Remove-Item -Force "${ExportDir}\addons.zip" -ErrorAction SilentlyContinue
Compress-Archive -Path "${tmpExportDir}\addons" -DestinationPath "${ExportDir}\addons.zip" -CompressionLevel Optimal -Force
Remove-Item -Force "$tmpExportDir" -Recurse -Confirm:$False -ErrorAction SilentlyContinue
Write-Log '---'
Write-Log "Addons exported successfully to ${ExportDir}\addons.zip" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}