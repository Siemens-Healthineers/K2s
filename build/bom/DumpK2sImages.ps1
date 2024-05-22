# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Creates a JSON file with list of all container images used in K2s.
.DESCRIPTION
Scraps container images from yaml manifest under addons folder and images configured in addon manifests.
.NOTES
Requires only the source code, no cluster needed.
.EXAMPLE
    $>  .\build\bom\Dumpk2sImages.ps1
#>

&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1

$addonsModule = "$PSScriptRoot\..\..\addons\addons.module.psm1"
$yamlModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.infra.module\yaml\yaml.module.psm1"

Import-Module $addonsModule, $yamlModule

$addonManifests = Find-AddonManifests -Directory "$global:KubernetesPath\addons" |`
    ForEach-Object {
    $manifest = Get-FromYamlFile -Path $_
    $manifest | Add-Member -NotePropertyName 'path' -NotePropertyValue $_
    $dirPath = Split-Path -Path $_ -Parent
    $dirName = Split-Path -Path $dirPath -Leaf
    $manifest | Add-Member -NotePropertyName 'dir' -NotePropertyValue @{path = $dirPath; name = $dirName }
    $manifest
}

Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Starting Scrapping of Container Images"

$finalJsonFile = "$PSScriptRoot\container-images-used.json"

if (Test-Path -Path $finalJsonFile) {
    Remove-Item -Force $finalJsonFile -ErrorAction SilentlyContinue
}

# Read the static images
$staticImages = Get-Content -Path "$global:KubernetesPath\build\bom\images\static-images.txt"
$images = @()

foreach ($manifest in $addonManifests) {
    $files = Get-Childitem -recurse $manifest.dir.path | Where-Object { $_.Name -match '.*.yaml$' } | ForEach-Object { $_.Fullname }

    foreach ($file in $files) {
        $imageLines = Get-Content $file | Select-String 'image:' | Select-Object -ExpandProperty Line
        foreach ($imageLine in $imageLines) {
            $images += (($imageLine -split 'image: ')[1] -split '#')[0]
        }
    }

    if ($null -ne $manifest.spec.offline_usage) {
        $linuxPackages = $manifest.spec.offline_usage.linux
        $additionImages = $linuxPackages.additionalImages
        $images += $additionImages
    }

    $images = $images | Select-Object -Unique | Where-Object { $_ -ne '' } | ForEach-Object { $_.Trim("`"'") }
}

$finalImages = ($staticImages + $images) | Select-Object -Unique
$imageDetailsArray = New-Object System.Collections.ArrayList

foreach ($image in $finalImages) {
    $imageName, $imageVersion = $image -split ':'
    
    if ($image -eq "") {
        continue
    }

    # Remove empty spaces
    $imageVersion = $imageVersion.Trim()
    Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Found image $image with version $imageVersion"

    # Determine the type of image
    $imageType = if ($staticImages -contains $image) { 'core' } else { 'addons' }

    $imageDetailsObject = New-Object PSObject -Property @{
        ImageName    = $imageName
        ImageVersion = $imageVersion
        ImageType    = $imageType
    }

    # Add the object to the array
    $imageDetailsArray.Add($imageDetailsObject) | Out-Null
}

# Output the image details in a JSON format file
$imageDetailsArray | ConvertTo-Json | Out-File -FilePath $finalJsonFile

Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Done Dumping Container Images"
