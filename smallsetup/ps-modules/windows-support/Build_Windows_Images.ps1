# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Builds the Windows-based images of a given 3rd-party tooling

.DESCRIPTION
Builds the Windows-based images of a given 3rd-party tooling with supporting manifests for all supported Windows versions.

.PARAMETER Registry
Registry to push to, e.g. 'k2s-registry.local'

.PARAMETER Name
Name of the image including paths, e.g. '/sig-storage/livenessprobe'

.PARAMETER Tag
Image tag, e.g. 'v1.2.3'

.PARAMETER Dockerfile
Dockerfile path

.PARAMETER RegUser
User for registry login

.PARAMETER RegPw
Password for registry login

.PARAMETER AllowInsecureRegistries
If set to true, insecure registries like local registries are allowed.
#>

Param(
    [parameter(Mandatory = $true, HelpMessage = "Registry to push to, e.g. 'k2s-registry.local'")]
    [string] $Registry,
    [parameter(Mandatory = $true, HelpMessage = "Name of the image including paths, e.g. '/sig-storage/livenessprobe' or 'livenessprobe'")]
    [string] $Name,
    [parameter(Mandatory = $true, HelpMessage = "Image tag, e.g. 'v1.2.3'")]
    [string] $Tag,
    [parameter(Mandatory = $true, HelpMessage = 'Dockerfile path')]
    [string] $Dockerfile,
    [parameter(Mandatory = $true, HelpMessage = 'WorkDir path')]
    [string] $WorkDir,
    [parameter(Mandatory = $true, HelpMessage = 'User for registry login')]
    [string] $RegUser,
    [parameter(Mandatory = $true, HelpMessage = 'Password for registry login')]
    [string] $RegPw,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, insecure registries like local registries are allowed.')]
    [switch] $AllowInsecureRegistries
)
Write-Output 'Windows images build started:'
Write-Output " - registry: $Registry"
Write-Output " - name: $Name"
Write-Output " - tag: $Tag"
Write-Output " - Dockerfile: $Dockerfile"
Write-Output " - allow insecure registries: $AllowInsecureRegistries"

Import-Module "$PSScriptRoot\..\docker\docker.module.psm1", "$PSScriptRoot\windows-support.module.psm1"

Install-WinDocker

Start-Service docker

Set-DockerToExpermental

Start-DockerLogin -Registry $Registry -RegUser $RegUser -RegPw $RegPw

$currentLocation = Get-Location

Set-Location $PSScriptRoot

try {
    if ($Name.StartsWith('/') -ne $true) {
        $Name = "/$($Name)"
    }

    $aggregateTag = "$($Registry)$($Name):$($Tag)"

    Write-Output "Creating images and manifest for tag '$aggregateTag'.."

    $versions = Get-WindowsImageVersions

    foreach ($version in $versions) {
        $targetTag = "$aggregateTag-$($version.TagSuffix)"

        Write-Output "  Building image for tag '$targetTag' based on Windows version '$($version.BaseVersion)'.."

        Start-BuildDockerImage -Tag $targetTag -Dockerfile $Dockerfile -ToolVersion $Tag -WindowsBaseVersion $($version.BaseVersion) -WorkDir $WorkDir

        Write-Output "  Pushing image '$targetTag' to '$Registry'.."

        Push-DockerImage -Tag $targetTag

        Write-Output "  Creating manifest for '$aggregateTag' with '$targetTag'.."

        New-DockerManifest -Tag $aggregateTag -AmmendTag $targetTag -AllowInsecureRegistries:$AllowInsecureRegistries

        Write-Output "  Annotating manifest '$aggregateTag' with '$targetTag', OS '$($version.OS)', arch '$($version.Arch)' and OS version '$($version.OSVersion)'.."

        New-DockerManifestAnnotation -Tag $aggregateTag -AmmendTag $targetTag -OS $version.OS -Arch $version.Arch -OSVersion $version.OSVersion
    }

    Write-Output "  Pushing manifest for '$aggregateTag' to '$Registry'.."

    Push-DockerManifest -Tag $aggregateTag -AllowInsecureRegistries:$AllowInsecureRegistries

    Write-Output "Images and manifest for tag '$aggregateTag' created."
}
finally {
    Set-Location $currentLocation
}