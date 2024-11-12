# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

&$PSScriptRoot\..\..\common\GlobalVariables.ps1

function Set-DockerToExpermental {
    $env:DOCKER_CLI_EXPERIMENTAL = 'enabled'

    &"$global:NssmInstallDirectory\nssm" restart docker

    if ($LASTEXITCODE -ne 0) {
        throw 'error while restarting Docker'
    }
}

function Start-DockerLogin {
    param (
        [parameter(Mandatory = $true, HelpMessage = "Registry to push to, e.g. 'k2s-registry.local'")]
        [string] $Registry,
        [parameter(Mandatory = $true, HelpMessage = 'User for registry login')]
        [string] $RegUser,
        [parameter(Mandatory = $true, HelpMessage = 'Password for registry login')]
        [string] $RegPw        
    )
    docker login -u $RegUser -p $RegPw $Registry

    if ($LASTEXITCODE -ne 0) {
        throw 'error while Docker login'
    }
}

function Start-BuildDockerImage {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Tag = $(throw 'Tag not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $Dockerfile = $(throw 'Dockerfile not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $WorkDir = $(throw 'WorkDir not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $ToolVersion = $(throw 'ToolVersion not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $WindowsBaseVersion = $(throw 'WindowsBaseVersion not specified')
    )
    docker image build -f "$Dockerfile" -t $Tag --build-arg TOOL_VERSION=$ToolVersion --build-arg WINDOWS_VERSION=$WindowsBaseVersion "$WorkDir"
     
    if ($LASTEXITCODE -ne 0) {
        throw 'error while building image'
    }
}

function Push-DockerImage {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Tag = $(throw 'Tag not specified')
    )
    docker push $Tag

    if ($LASTEXITCODE -ne 0) {
        throw 'error while pushing image'
    }
}

function New-DockerManifest {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Tag = $(throw 'Tag not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $AmmendTag = $(throw 'AmmendTag not specified'),
        [parameter(Mandatory = $false, HelpMessage = 'If set to true, insecure registries like local registries are allowed.')]
        [switch] $AllowInsecureRegistries     
    )
    if ($AllowInsecureRegistries -eq $true) {
        docker manifest create --insecure $Tag --amend $AmmendTag    
    }
    else {
        docker manifest create $Tag --amend $AmmendTag
    }            

    if ($LASTEXITCODE -ne 0) {
        throw 'error while creating manifest'
    }
}

function New-DockerManifestAnnotation {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Tag = $(throw 'Tag not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $AmmendTag = $(throw 'AmmendTag not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $OS = $(throw 'OS not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $Arch = $(throw 'Arch not specified'),
        [string]
        $OSVersion = $(throw 'OSVersion not specified')    
    )
    docker manifest annotate --os $OS --arch $Arch --os-version $OSVersion $Tag $AmmendTag

    if ($LASTEXITCODE -ne 0) {
        throw 'error while annotating manifest'
    }
}

function Push-DockerManifest {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Tag = $(throw 'Tag not specified'),
        [parameter(Mandatory = $false, HelpMessage = 'If set to true, insecure registries like local registries are allowed.')]
        [switch] $AllowInsecureRegistries   
    )
    if ($AllowInsecureRegistries -eq $true) {
        docker manifest push --insecure $Tag
    }
    else {
        docker manifest push $Tag
    }          

    if ($LASTEXITCODE -ne 0) {
        throw 'error pushing manifest'
    }
}

Export-ModuleMember -Function Set-DockerToExpermental, Start-DockerLogin, Start-BuildDockerImage, Push-DockerImage, New-DockerManifest, New-DockerManifestAnnotation, Push-DockerManifest