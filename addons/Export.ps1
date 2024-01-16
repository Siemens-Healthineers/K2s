# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
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
    [string[]] $Names
)

# load global settings
&$PSScriptRoot\..\smallsetup\common\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\..\smallsetup\common\GlobalFunctions.ps1

Import-Module $PSScriptRoot\..\smallsetup\helpers\ImageFunctions.module.psm1 -DisableNameChecking
Import-Module $PSScriptRoot\..\smallsetup\helpers\RegistryFunctions.module.psm1 -DisableNameChecking
Import-Module $PSScriptRoot\Addons.module.psm1
Import-Module $PSScriptRoot\..\smallsetup\status\SetupType.module.psm1
Import-Module $PSScriptRoot\..\smallsetup\status\RunningState.module.psm1
Import-Module $PSScriptRoot\..\smallsetup\ps-modules\log\log.module.psm1
Import-Module $PSScriptRoot\..\lib\modules\k2s\k2s.infra.module\yaml\yaml.module.psm1
Initialize-Logging -ShowLogs:$ShowLogs

$setupType = Get-SetupType
if ($setupType.ValidationError) {
    throw $setupType.ValidationError
}

if ($setupType.LinuxOnly) {
    throw 'Cannot export addons with linux-only setup.'
}

$clusterState = Get-RunningState -SetupType $setupType.Name

if ($clusterState.IsRunning -ne $true) {
    throw "Cannot export addons when cluster is not running. Please start the cluster with 'k2s start'."
}

Remove-Item -Force "${ExportDir}\addons" -Recurse -Confirm:$False -ErrorAction SilentlyContinue
mkdir -Force "${ExportDir}\addons" | Out-Null

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
            throw "no addon with name '$name' found"
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

        mkdir -Force "${ExportDir}\addons\$($manifest.dir.name)" | Out-Null

        foreach ($image in $linuxImages) {
            Write-Log "Pulling linux image $image"
            ExecCmdMaster "sudo buildah pull $image 2>&1" -Retries 5
        }

        foreach ($image in $windowsImages) {
            Write-Log "Pulling windows image $image"
            if ($setupType.Name -eq $global:SetupType_MultiVMK8s) {
                $session = Open-RemoteSessionViaSSHKey $global:Admin_WinNode $global:WindowsVMKey
                Invoke-Command -Session $session {
                    Set-Location "$env:SystemDrive\k"
                    Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

                    # load global settings
                    &$env:SystemDrive\k\smallsetup\common\GlobalVariables.ps1

                    &$global:NerdctlExe -n 'k8s.io' pull $using:image --platform windows/amd64 2>&1 | Out-Null
                    crictl pull $using:image
                }
            }
            else {
                &$global:NerdctlExe -n 'k8s.io' pull $image --platform windows/amd64 2>&1 | Out-Null
                crictl pull $image
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

                if ($linuxImageToExportArray -and $linuxImageToExportArray.Count -gt 0) {
                    $imageToExport = $linuxImageToExportArray[0]
                    &$global:KubernetesPath\smallsetup\helpers\ExportImage.ps1 -Id $imageToExport.ImageId -ExportPath "${ExportDir}\addons\$($manifest.dir.name)\${count}.tar" -ShowLogs:$ShowLogs

                    if (!$?) {
                        Write-Error "Image $imageNameWithoutTag could not be exported!"
                    }

                    $count += 1
                }

                if ($windowsImageToExportArray -and $windowsImageToExportArray.Count -gt 0) {
                    $imageToExport = $windowsImageToExportArray[0]
                    &$global:KubernetesPath\smallsetup\helpers\ExportImage.ps1 -Id $imageToExport.ImageId -ExportPath "${ExportDir}\addons\$($manifest.dir.name)\${count}_win.tar" -ShowLogs:$ShowLogs

                    if (!$?) {
                        Write-Error "Image $imageNameWithoutTag could not be exported!"
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
                $setupType = Get-SetupType
                if ($setupType.ValidationError) {
                    throw $setupType.ValidationError
                }

                foreach ($repo in $repos) {
                    if ($setupType.Name -ne $global:SetupType_MultiVMK8s) {
                        $repoWithReplacedHttpProxyPlaceHolder = $repo.Replace('__LOCAL_HTTP_PROXY__', $global:HttpProxy)
                    }
                    else {
                        $repoWithReplacedHttpProxyPlaceHolder = $repo.Replace('__LOCAL_HTTP_PROXY__', "''")
                    }
                    ExecCmdMaster "$repoWithReplacedHttpProxyPlaceHolder"
                }

                ExecCmdMaster 'sudo apt-get update > /dev/null 2>&1'
            }

            # download debian packages
            $debianPackages = $linuxPackages.deb
            if ($debianPackages) {
                ExecCmdMaster 'sudo apt-get clean > /dev/null 2>&1'
                foreach ($package in $debianPackages) {
                    if (!(Get-DebianPackageAvailableOffline -addon $manifest.dir.name -package $package)) {
                        Write-Log "Downloading debian package `"$package`" with dependencies"
                        ExecCmdMaster "sudo DEBIAN_FRONTEND=noninteractive apt-get --download-only reinstall -y $package > /dev/null 2>&1"
                        ExecCmdMaster "mkdir -p .$($manifest.dir.name)/${package}"
                        ExecCmdMaster "sudo cp /var/cache/apt/archives/*.deb .$($manifest.dir.name)/${package}"
                        ExecCmdMaster 'sudo apt-get clean > /dev/null 2>&1'
                    }
                }

                mkdir -Force "${ExportDir}\addons\$($manifest.dir.name)\debianpackages" | Out-Null
                Copy-FromToMaster $($global:Remote_Master + ':' + ".$($manifest.dir.name)/*") "${ExportDir}\addons\$($manifest.dir.name)\debianpackages"
            }

            # download linux packages via curl
            $linuxCurlPackages = $linuxPackages.curl
            if ($linuxCurlPackages) {
                mkdir -Force "${ExportDir}\addons\$($manifest.dir.name)\linuxpackages" | Out-Null
                foreach ($package in $linuxCurlPackages) {
                    $filename = ([uri]$package.url).Segments[-1]
                    DownloadFile "${ExportDir}\addons\$($manifest.dir.name)\linuxpackages\${filename}" $package.url $true -ProxyToUse $Proxy
                }
            }

            # download windows packages via curl
            $windowsPackages = $manifest.spec.offline_usage.windows
            $windowsCurlPackages = $windowsPackages.curl
            if ($windowsCurlPackages) {
                mkdir -Force "${ExportDir}\addons\$($manifest.dir.name)\windowspackages" | Out-Null
                foreach ($package in $windowsCurlPackages) {
                    $filename = ([uri]$package.url).Segments[-1]
                    DownloadFile "${ExportDir}\addons\$($manifest.dir.name)\windowspackages\${filename}" $package.url $true -ProxyToUse $Proxy
                }
            }
        }

        Write-Log '---' -Console        
    }

    $addonExportInfo = @{addons = @() }
    $addonManifests | ForEach-Object { $addonExportInfo.addons += @{name = $_.metadata.name; dirName = $_.dir.name; offline_usage = $_.spec.offline_usage } } 
    $addonExportInfo | ConvertTo-Json -Depth 100 | Set-Content -Path "${ExportDir}\addons\addons.json" -Force
}
finally {
    $env:http_proxy = $currentHttpProxy
    $env:https_proxy = $currentHttpsProxy
}

Remove-Item -Force "${ExportDir}\addons.zip" -ErrorAction SilentlyContinue
Compress-Archive -Path "${ExportDir}\addons" -DestinationPath "${ExportDir}\addons.zip" -CompressionLevel Optimal -Force
Remove-Item -Force "${ExportDir}\addons" -Recurse -Confirm:$False -ErrorAction SilentlyContinue
Write-Log '---'
Write-Log "Addons exported successfully to ${ExportDir}\addons.zip" -Console
