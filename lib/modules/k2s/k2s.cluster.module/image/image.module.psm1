# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

$registryFunctionsModule = "$PSScriptRoot\registry\registry.module.psm1"
$k8sApiModule = "$PSScriptRoot\..\k8s-api\k8s-api.module.psm1"
$statusModule = "$PSScriptRoot\..\status\status.module.psm1"
$configModule = "$PSScriptRoot\..\..\k2s.infra.module\config\config.module.psm1"
$vmModule = "$PSScriptRoot\..\..\k2s.node.module\linuxnode\vm\vm.module.psm1"
$pathModule = "$PSScriptRoot\..\..\k2s.infra.module\path\path.module.psm1"

Import-Module $configModule, $k8sApiModule, $registryFunctionsModule, $vmModule, $statusModule, $pathModule

$kubernetesImagesJson = Get-KubernetesImagesFilePath
$windowsPauseImageRepository = 'shsk2s.azurecr.io/pause-win'
$kubeBinPath = Get-KubeBinPath
$dockerExe = "$kubeBinPath\docker\docker.exe"

class ContainerImage {
    [string]$ImageId
    [string]$Repository
    [string]$Tag
    [string]$Node
    [string]$Size
}

class PushedImage {
    [string]$Name
    [string]$Tag
}

$headers = @(
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.oci.artifact.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.docker.distribution.manifest.v1+prettyjws",
    "application/vnd.docker.distribution.manifest.v1+json"
)
$concatinatedHeadersString = ""
$headers | ForEach-Object { $concatinatedHeadersString += " -H `"Accept: $_`""  }

function New-KubernetesImageJsonFileIfNotExists() {
    $fileExists = Test-Path -Path $kubernetesImagesJson
    if (!$fileExists) {
        New-Item -Path $kubernetesImagesJson | Out-Null

        '[]' | Set-Content -Path "$kubernetesImagesJson"
    }
}

function Get-KubernetesImagesFromJson() {
    New-KubernetesImageJsonFileIfNotExists
    $kubernetesImages = @(Get-Content -Path $kubernetesImagesJson -Raw | ConvertFrom-Json)
    return $kubernetesImages
}

<#
.DESCRIPTION
This function is used to collect the kubernetes images present on the nodes.
!!! CAUTION !!! This function must be called only during installation. Otherwise, user's images will also be written into the json file.
User will see an incorrect output on listing images.
#>
function Write-KubernetesImagesIntoJson {
    param (
        [Parameter(Mandatory = $false)]
        [Object[]] $LinuxImagesRaw,
        [Parameter(Mandatory = $false)]
        [Object[]] $WindowsImagesRaw,
        [Parameter(Mandatory = $false)]
        [string] $WindowsNodeName
    )

    New-KubernetesImageJsonFileIfNotExists
    $kubernetesImages = @()
    $linuxKubernetesImages = Get-ContainerImagesOnLinuxNode
    $windowsKubernetesImages = $(Get-ContainerImagesOnWindowsNode -IncludeK8sImages $false -WindowsImagesRaw $WindowsImagesRaw -WindowsNodeName $WindowsNodeName) | Where-Object { $_.Repository -match $windowsPauseImageRepository }
    $kubernetesImages = @($linuxKubernetesImages) + @($windowsKubernetesImages)
    $kubernetesImagesJsonString = $kubernetesImages | ConvertTo-Json -Depth 100
    $kubernetesImagesJsonString | Set-Content -Path $kubernetesImagesJson
}

function Get-FilteredImages([ContainerImage[]]$ContainerImages, [ContainerImage[]]$ContainerImagesToBeCleaned) {
    $filteredImages = @()
    foreach ($containerImage in $ContainerImages) {
        $count = ($ContainerImagesToBeCleaned | Where-Object { $_.ImageId -eq $containerImage.ImageId } ).Count
        if ($count -eq 0 ) {
            $filteredImages += $containerImage
        }
    }
    return $filteredImages
}

function Get-ContainerImagesOnLinuxNode([bool]$IncludeK8sImages = $false) {
    $setupFilePath = Get-SetupConfigFilePath
    $hostname = Get-ConfigValue -Path $setupFilePath -Key 'ControlPlaneNodeHostname'
    $KubernetesImages = Get-KubernetesImagesFromJson
    $linuxContainerImages = @()
    $output = Invoke-CmdOnControlPlaneViaSSHKey 'sudo buildah images' -NoLog
    foreach ($line in $output[1..($output.Count - 1)]) {
        $words = $($line -replace '\s+', ' ').split()
        $containerImage = [ContainerImage]@{
            ImageId    = $words[2]
            Repository = $words[0]
            Tag        = $words[1]
            Node       = "$hostname"
            Size       = $words[$words.Count - 2] + $words[$words.Count - 1]
        }
        $linuxContainerImages += $containerImage
    }
    if ($IncludeK8sImages -eq $false) {
        $linuxContainerImages =
        Get-FilteredImages -ContainerImages $linuxContainerImages -ContainerImagesToBeCleaned $KubernetesImages
    }
    return $linuxContainerImages
}

function Get-ContainerImagesOnWindowsNode([bool]$IncludeK8sImages = $false, [Object[]]$WindowsImagesRaw, $WindowsNodeName) {

    $kubeBinPath = Get-KubeBinPath
    $output = ''
    $node = ''
    if ($null -ne $WindowsImagesRaw) {
        # We have the raw list of images already
        $output = $WindowsImagesRaw
        $node = $WindowsNodeName
    } else {
        $output = &$kubeBinPath\crictl.exe images 2> $null
        $node = $env:ComputerName.ToLower()
    }

    $KubernetesImages = Get-KubernetesImagesFromJson

    $windowsContainerImages = @()
    if ($output.Count -gt 1) {
        foreach ( $line in $output[1..($output.Count - 1)]) {
            $words = $($line -replace '\s+', ' ').split()
            $containerImage = [ContainerImage]@{
                ImageId    = $words[2]
                Repository = $words[0]
                Tag        = $words[1]
                Size       = $words[3]
                Node       = $node
            }
            $windowsContainerImages += $containerImage
        }
        if ($IncludeK8sImages -eq $false) {
            $windowsContainerImages =
            Get-FilteredImages -ContainerImages $windowsContainerImages -ContainerImagesToBeCleaned $KubernetesImages
        }
    }
    return $windowsContainerImages
}

function Get-PushedContainerImages() {
    $setupFilePath = Get-SetupConfigFilePath
    $enableAddons = Get-ConfigValue -Path $setupFilePath -Key 'EnabledAddons'
    $isRegistryAddonEnabled = $enableAddons | Select-Object -Property Name | Where-Object { $_ -eq "registry" }
    if (!$isRegistryAddonEnabled) {
        return
    }

    $registryName = $(Get-RegistriesFromSetupJson) | Where-Object { $_ -match 'k2s-registry.*' }
    $auth = Get-RegistryAuthToken $registryName
    if (!$auth) {
        Write-Error "Can't find authentification token for $registryName."
        return
    }

    $catalog = $(curl.exe --retry 3 --retry-connrefused -X GET http://$registryName/v2/_catalog -H "Authorization: Basic $auth") 2> $null | Out-String | ConvertFrom-Json

    $images = $catalog.psobject.properties['repositories'].value

    $pushedContainerImages = @()
    foreach ($image in $images) {
        $imageWithTags = curl.exe --retry 3 --retry-connrefused -X GET http://$registryName/v2/$image/tags/list -H "Authorization: Basic $auth" 2> $null | Out-String | ConvertFrom-Json
        $tags = $imageWithTags.psobject.properties['tags'].value

        foreach ($tag in $tags) {
            $pushedimage = [PushedImage]@{
                Name = "$registryName/" + $image
                Tag  = $tag
            }
            $pushedContainerImages += $pushedimage
        }
    }

    return $pushedContainerImages
}

function Remove-Image([ContainerImage]$ContainerImage) {
    $output = ''
    if ($containerImage.Node -eq $env:ComputerName.ToLower()) {
        $output = $(crictl rmi $containerImage.ImageId 2>&1)
    }
    else {
        $imageId = $containerImage.ImageId
        $output = Invoke-CmdOnControlPlaneViaSSHKey "sudo crictl rmi $imageId" -NoLog
    }

    $errorString = Get-ErrorMessageIfImageDeletionFailed -Output $output

    return $errorString
}

function Remove-PushedImage($name, $tag) {
    $registryName = $(Get-RegistriesFromSetupJson) | Where-Object { $_ -match 'k2s-registry.*' }
    $auth = Get-RegistryAuthToken $registryName
    if (!$auth) {
        Write-Error "Can't find authentification token for $registryName."
        return
    }

    if ($name.Contains("$registryName/")) {
        $name = $name.Replace("$registryName/", '')
    }

    $status = $null
    $statusDescription = $null

    $headRequest = "curl.exe -m 10 --retry 3 --retry-connrefused -I http://$registryName/v2/$name/manifests/$tag -H 'Authorization: Basic $auth' $concatinatedHeadersString -v 2>&1"
    $headResponse = Invoke-Expression $headRequest
    foreach ($line in $headResponse) {
        if ($line -match 'HTTP/1.1 (\d{3}) (.+)') {
            # Extract the HTTP status code and description
            $status = $matches[1]
            $statusDescription = $matches[2]
            break
        }
    }
    $imageName = $name + ':' + $tag
    if ($status -eq '200') {
        Write-Output "Successfully retreived digest for $imageName from $registryName"
    }
    else {
        Write-Error "An error occurred while getting digest. HTTP Status Code: $status $statusDescription"
    }


    $lineWithDigest = $headResponse | Select-String 'Docker-Content-Digest:' | Select-Object -ExpandProperty Line -First 1
    $match = Select-String 'Docker-Content-Digest: (.*)' -InputObject $lineWithDigest
    $digest = $match.Matches.Groups[1].Value

    $deleteRequest = "curl.exe -m 10 -I --retry 3 --retry-connrefused -X DELETE http://$registryName/v2/$name/manifests/$digest -H 'Authorization: Basic $auth' $concatinatedHeadersString -v 2>&1"
    $deleteResponse = Invoke-Expression $deleteRequest

    foreach ($line in $deleteResponse) {
        if ($line -match 'HTTP/1.1 (\d{3}) (.+)') {
            # Extract the HTTP status code and description
            $status = $matches[1]
            $statusDescription = $matches[2]
            break
        }
    }

    $imageName = $name + ':' + $tag
    if ($status -eq '202') {
        Write-Output "Successfully deleted image $imageName from $registryName"
    }
    else {
        Write-Error "An error occurred while deleting image. HTTP Status Code: $status $statusDescription"
    }
}

function Get-RegistryAuthToken($registryName) {
    # read auth
    $authJson = Invoke-CmdOnControlPlaneViaSSHKey 'sudo cat /root/.config/containers/auth.json' -NoLog
    $dockerConfig = $authJson | ConvertFrom-Json
    $dockerAuth = $dockerConfig.psobject.properties['auths'].value
    $authk2s = $dockerAuth.psobject.properties["$registryName"].value
    $auth = $authk2s.psobject.properties['auth'].value
    return $auth
}

function Get-ContainerImagesInk2s([bool]$IncludeK8sImages = $false) {
    $linuxContainerImages = Get-ContainerImagesOnLinuxNode -IncludeK8sImages $IncludeK8sImages
    $windowsContainerImages = Get-ContainerImagesOnWindowsNode -IncludeK8sImages $IncludeK8sImages
    $allContainerImages = @($linuxContainerImages) + @($windowsContainerImages)
    return $allContainerImages
}

function Get-ErrorMessageIfImageDeletionFailed([string]$Output) {
    if ($output.Contains('image is in use by a container')) {
        return 'Unable to delete the image as it is in use by a container.'
    }
    elseif ($output.Contains('context deadline exceeded')) {
        return 'Unable to delete the image as the operation timed-out.'
    }
    elseif ($output.Contains('no such image')) {
        return 'Unable to delete the image as it was not found.'
    }
    else {
        return $null
    }
}

function Show-ImageDeletionStatus([ContainerImage]$ContainerImage, [string]$ErrorMessage) {
    $imageName = $ContainerImage.Repository + ':' + $ContainerImage.Tag
    $node = $ContainerImage.Node
    if ([string]::IsNullOrWhiteSpace($ErrorMessage)) {
        Write-Host "Successfully deleted image $imageName from $node"
    }
    else {
        Write-Host "Failed to delete image $imageName from $node. Reason: $ErrorMessage"
    }
}

function Get-BuildArgs([string[]]$buildArgs) {
    $buildArgString = ''
    foreach ($buildArgValuePair in $buildArgs) {
        $array = $buildArgValuePair.Split('=')
        $name = $array[0]
        $value = $array[1]
        $buildArgString += "--build-arg $name=$value "
    }
    if ($buildArgString.Length -gt 0) {
        $buildArgString = $buildArgString.Substring(0, $buildArgString.Length - 1)
    }
    return $buildArgString
}

function Get-DockerfileAbsolutePathAndPreCompileFlag {
    param(
        [Parameter()]
        [String] $InputFolder,
        [Parameter()]
        [String] $Dockerfile,
        [Parameter()]
        [switch] $PreCompile
    )

    if ($Dockerfile -ne '') {
        $filePath = ''
        try {
            # try to resolve the path relative to current working directory first.
            $filePath = (Resolve-Path -Path $Dockerfile -ErrorAction Stop).Path
        }
        catch {
            # if this fails, try to resolve it relative to Input folder.
            # if this also fails, stop execution
            Write-Log "Could not resolve Dockerfile from current working directory. We will now try to resolve it from $InputFolder"
            if (! (Test-Path "$InputFolder\$Dockerfile")) { throw 'Unable to find Dockerfile' }
            $filePath = "$InputFolder\$Dockerfile"
        }
        # We return PreCompile flag
        return $filePath, $PreCompile
    }

    if ($Dockerfile -eq '' -and $PreCompile) {
        $Dockerfile = 'Dockerfile.PreCompile'
        Write-Log "Pre-Compilation: using $Dockerfile"
    }

    # set defaults if no dockerfile given: If Dockerfile.PreCompile is available, use that,
    # otherwise use Dockerfile
    if ($Dockerfile -eq '') {
        $Dockerfile = 'Dockerfile.PreCompile'
        if (Test-Path "$InputFolder\$Dockerfile") {
            $PreCompile = $True
            Write-Log "Pre-Compilation: using $Dockerfile"
        }
        else {
            $Dockerfile = 'Dockerfile'
            Write-Log "Full: using $Dockerfile"
        }
    }
    if (! (Test-Path "$InputFolder\$Dockerfile")) { throw "Missing Dockerfile: $InputFolder\$Dockerfile" }

    $filePath = "$InputFolder\$Dockerfile"
    return $filePath, $PreCompile
}

function New-WindowsImage {
    param(
        [Parameter()]
        [String] $InputFolder,
        [Parameter()]
        [String] $Dockerfile,
        [Parameter()]
        [String] $ImageName,
        [Parameter()]
        [String] $ImageTag,
        [Parameter()]
        [String] $NoCacheFlag,
        [Parameter()]
        [String] $BuildArgsString
    )
    $shouldStopDocker = $false
    $svc = (Get-Service 'docker' -ErrorAction Stop)
    if ($svc.Status -ne 'Running') {
        Write-Log 'Starting docker backend...'
        Start-Service docker
        $shouldStopDocker = $true
    }

    $imageFullName = "${ImageName}:$ImageTag"

    Write-Log "Building Windows image $imageFullName" -Console
    if ($BuildArgsString -ne '') {
        $cmd = "$dockerExe build ""$InputFolder"" -f ""$Dockerfile"" --force-rm $NoCacheFlag -t $imageFullName $BuildArgsString"
        Write-Log "Build cmd: $cmd"
        Invoke-Expression -Command $cmd
    }
    else {
        $cmd = "$dockerExe build ""$InputFolder"" -f ""$Dockerfile"" --force-rm $NoCacheFlag -t $imageFullName"
        Write-Log "Build cmd: $cmd"
        Invoke-Expression -Command $cmd
    }
    if ($LASTEXITCODE -ne 0) { throw "error while creating image with 'docker build' on Windows. Error code returned was $LastExitCode" }

    Write-Log "Output of checking if the image $imageFullName is now available in docker:"
    &$dockerExe image ls $ImageName -a

    Write-Log $global:ExportedImagesTempFolder
    if (!(Test-Path($global:ExportedImagesTempFolder))) {
        New-Item -Force -Path $global:ExportedImagesTempFolder -ItemType Directory
    }
    $exportedImageFullFileName = $global:ExportedImagesTempFolder + '\BuiltImage.tar'
    if (Test-Path($exportedImageFullFileName)) {
        Remove-Item $exportedImageFullFileName -Force
    }

    Write-Log "Saving image $imageFullName temporarily as $exportedImageFullFileName to import it afterwards into containerd..."
    &$dockerExe save -o "$exportedImageFullFileName" $imageFullName
    if (!$?) { throw "error while saving built image '$imageFullName' with 'docker save' on Windows. Error code returned was $LastExitCode" }
    Write-Log '...saved.'

    Write-Log "Importing image $imageFullName from $exportedImageFullFileName into containerd..."
    &$global:NerdctlExe -n k8s.io load -i "$exportedImageFullFileName"
    if (!$?) { throw "error while importing built image '$imageFullName' with 'nerdctl.exe load' on Windows. Error code returned was $LastExitCode" }
    Write-Log '...imported'

    Write-Log "Removing temporarily created file $exportedImageFullFileName..."
    Remove-Item $exportedImageFullFileName -Force
    Write-Log '...removed'

    $imageList = &$global:CtrExe -n="k8s.io" images list | Out-string

    if (!$imageList.Contains($imageFullName)) {
        throw "The built image '$imageFullName' was not imported in the containerd's local repository."
    }
    Write-Log "The built image '$imageFullName' is available in the containerd's local repository."

    if ($shouldStopDocker) {
        Write-Log 'Stopping docker backend...'
        Stop-Service docker
    }
}

Export-ModuleMember -Function Get-ContainerImagesInk2s,
Remove-Image,
Get-PushedContainerImages,
Remove-PushedImage,
Show-ImageDeletionStatus,
Get-ContainerImagesOnLinuxNode,
Get-ContainerImagesOnWindowsNode,
Write-KubernetesImagesIntoJson,
Get-BuildArgs,
Get-DockerfileAbsolutePathAndPreCompileFlag,
New-WindowsImage
