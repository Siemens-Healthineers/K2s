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

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Name of Addons to dump container images')]
    [string[]] $Addons
)

&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1

$addonsModule = "$PSScriptRoot\..\..\addons\addons.module.psm1"
$yamlModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.infra.module\yaml\yaml.module.psm1"

Import-Module $addonsModule, $yamlModule

$addonManifests = @()

Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Starting Scrapping of Container Images for all addons"
$allAddonManifests = Find-AddonManifests -Directory "$global:KubernetesPath\addons\" |`
    ForEach-Object {
    $manifest = Get-FromYamlFile -Path $_
    $manifest | Add-Member -NotePropertyName 'path' -NotePropertyValue $_
    $dirPath = Split-Path -Path $_ -Parent
    $dirName = Split-Path -Path $dirPath -Leaf
    $manifest | Add-Member -NotePropertyName 'dir' -NotePropertyValue @{path = $dirPath; name = $dirName }
    $manifest
}

if ($Addons.Count -eq 0) {
    $addonManifests += $allAddonManifests
}
else {    
    foreach ($name in $Addons) {
        Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Filter Container Images for addon: $name"
        $foundManifest = $null
        $addonName = ($name -split " ")[0]
        $implementationName = ($name -split " ")[1]

        foreach ($manifest in $allAddonManifests) {
            if ($manifest.metadata.name -eq $addonName) {
                $foundManifest = $manifest

                # specific implementation specified
                if ($null -ne $implementationName) {
                    $foundManifest.spec.implementations = $foundManifest.spec.implementations | Where-Object { $_.name -eq $implementationName}
                }
                break
            }
        }

        if ($null -eq $foundManifest) {
            Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] No addon manifest for addon: $name"
        } else {
            $addonManifests += $foundManifest
        }
    }
}

$finalJsonFile = "$PSScriptRoot\container-images-used.json"

if (Test-Path -Path $finalJsonFile) {
    Remove-Item -Force $finalJsonFile -ErrorAction SilentlyContinue
}

# Read the static images
$staticImages = Get-Content -Path "$global:KubernetesPath\build\bom\images\static-images.txt"
$images = @()
$addonImages = @()
$addonNameImagesMapping = @{}


foreach ($manifest in $addonManifests) {
    foreach ($implementation in $manifest.spec.implementations) {
        # there are more than one implementation
        $dirPath = $manifest.dir.path
        $addonName = $manifest.metadata.name
        if ($implementation.name -ne $manifest.metadata.name) {
            $dirPath = Join-Path -Path $($manifest.dir.path) -ChildPath $($implementation.name)
            $addonName += " $($implementation.name)"
        }
        $files = Get-Childitem -recurse $dirPath | Where-Object { $_.Name -match '.*.yaml$' } | ForEach-Object { $_.Fullname }

        foreach ($file in $files) {
            $imageLines = Get-Content $file | Select-String 'image:' | Select-Object -ExpandProperty Line

            foreach ($imageLine in $imageLines) {
                $unTrimmedFullImageName = (($imageLine -split 'image: ')[1] -split '#')[0]
                $fullImageName = $unTrimmedFullImageName.Trim().Trim("`"'")

                if ($fullImageName -eq '') {
                    continue
                }

                $images += "$fullImageName"

                # Initialize the image list if not already present
                if (-not $addonNameImagesMapping.ContainsKey($addonName)) {
                    $addonNameImagesMapping[$addonName] = @()
                }

                # Add the image name if it does not already exist in the list
                if (-not ($addonNameImagesMapping[$addonName] -contains $fullImageName)) {
                    $addonNameImagesMapping[$addonName] += "$fullImageName"
                }
            }

        }

        if ($null -ne $implementation.offline_usage) {
            $linuxPackages = $implementation.offline_usage.linux
            $additionImages = $linuxPackages.additionalImages

            if ($additionImages.Count -ne 0) {
                if (-not $addonNameImagesMapping.ContainsKey($addonName)) {
                    $addonNameImagesMapping[$addonName] = @()
                }

                if (-not ($addonNameImagesMapping[$addonName] -contains $additionImages)) {
                    $addonNameImagesMapping[$addonName] += $additionImages
                }
                $images += $additionImages
            }
        }

        $addonImages = $images | Select-Object -Unique | Where-Object { $_ -ne '' } | ForEach-Object { $_.Trim("`"'") }
    }
}


$totalCountMapping = 0

foreach ($addonName in $addonNameImagesMapping.Keys) {
    $uniqueImages = $addonNameImagesMapping[$addonName] | Sort-Object -Unique
    $finalImages = @()
    $finalImages = $uniqueImages -notlike ''
    $totalCountMapping = $totalCountMapping + $($finalImages.Count)
    Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Addon: $addonName"
    Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Addon Images Count: $($finalImages.Count)"
    Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Images: $([string]::Join(', ', $uniqueImages))"
    Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] -----------------------------------------------------------------------------"
}

Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Number of addon images: $($addonImages.Count)"
Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Number of images in mapping: $totalCountMapping"

if ($($addonImages.Count) -ne $totalCountMapping) {
    Write-Warning "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Check the image mapping and addon list for duplicates or a single image referenced by two addons"
}

$finalImages = ($staticImages + $addonImages) | Select-Object -Unique
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

    $referrerName = 'core'
    if ($imageType -eq 'addons') {
        # Look for addon name using image name
        foreach ($addonName in $addonNameImagesMapping.Keys) {

            $tempImages = $addonNameImagesMapping[$addonName]
            #Write-Output "Addon images '$addonName' $([string]::Join(', ', $tempImages))"

            if ($tempImages.contains("$image")) {
                Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Belongs to addon '$addonName'"
                $referrerName = $addonName
                break
            }
        }

        if ($referrerName -eq 'core') {
            throw "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Unable to find addon referring image: $image !!!"
        }
    }


    $imageDetailsObject = New-Object PSObject -Property @{
        ImageName    = $imageName
        ImageVersion = $imageVersion
        ImageType    = $imageType
        ImageRef     = $referrerName
    }

    # Add the object to the array
    $imageDetailsArray.Add($imageDetailsObject) | Out-Null
    Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] *********************************************************************************"
}

# Output the image details in a JSON format file
$imageDetailsArray | ConvertTo-Json | Out-File -FilePath $finalJsonFile

Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Done Dumping Container Images"
