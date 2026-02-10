# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

$registryFunctionsModule = "$PSScriptRoot\registry\registry.module.psm1"
$k8sApiModule = "$PSScriptRoot\..\k8s-api\k8s-api.module.psm1"
$statusModule = "$PSScriptRoot\..\status\status.module.psm1"
$configModule = "$PSScriptRoot\..\..\k2s.infra.module\config\config.module.psm1"
$vmModule = "$PSScriptRoot\..\..\k2s.node.module\linuxnode\vm\vm.module.psm1"
$pathModule = "$PSScriptRoot\..\..\k2s.infra.module\path\path.module.psm1"
$vmNodeModule = "$PSScriptRoot\..\..\k2s.node.module\vmnode\vmnode.module.psm1"

Import-Module $configModule, $k8sApiModule, $registryFunctionsModule, $vmModule, $statusModule, $pathModule, $vmNodeModule

$kubernetesImagesJson = Get-KubernetesImagesFilePath
$windowsPauseImageRepository = 'shsk2s.azurecr.io/pause-win'
$kubeBinPath = Get-KubeBinPath
$dockerExe = "$kubeBinPath\docker\docker.exe"
$nerdctlExe = "$kubeBinPath\nerdctl.exe"
$ctrExe = "$kubeBinPath\containerd\ctr.exe"
$crictlExe = Get-CrictlExePath
$rootConfig = Get-RootConfigk2s
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
    'application/vnd.oci.image.manifest.v1+json',
    'application/vnd.oci.image.index.v1+json',
    'application/vnd.oci.artifact.manifest.v1+json',
    'application/vnd.docker.distribution.manifest.v2+json',
    'application/vnd.docker.distribution.manifest.list.v2+json',
    'application/vnd.docker.distribution.manifest.v1+prettyjws',
    'application/vnd.docker.distribution.manifest.v1+json'
)
$concatenatedHeadersString = ''
$headers | ForEach-Object { $concatenatedHeadersString += " -H `"Accept: $_`"" }

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
    New-KubernetesImageJsonFileIfNotExists
    $kubernetesImages = @()
    $linuxKubernetesImages = Get-ContainerImagesOnLinuxNode
    $windowsKubernetesImages = $(Get-ContainerImagesOnWindowsNode -IncludeK8sImages $false) | Where-Object { $_.Repository -match $windowsPauseImageRepository }
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

function Get-ContainerImagesOnLinuxNode([bool]$IncludeK8sImages = $false, [bool]$ExcludeAddonImages = $false) {
    $setupFilePath = Get-SetupConfigFilePath
    $hostname = Get-ConfigValue -Path $setupFilePath -Key 'ControlPlaneNodeHostname'
    $KubernetesImages = Get-KubernetesImagesFromJson
    $linuxContainerImages = @()
    $output = (Invoke-CmdOnControlPlaneViaSSHKey 'sudo buildah images').Output

    Write-Log "[ImageList] Raw output type = $($output.GetType().Name)"
    Write-Log "[ImageList] Raw output count = $($output.Count)"
    if ($output -is [array]) {
        Write-Log "[ImageList] Output is array with $($output.Length) elements"
        for ($i = 0; $i -lt [Math]::Min($output.Length, 10); $i++) {
            Write-Log "[ImageList]   Line[$i]: '$($output[$i])'"
        }
    } else {
        Write-Log "[ImageList] Output is single value: '$output'"
    }

    foreach ($line in $output[1..($output.Count - 1)]) {
        $words = $($line -replace '\s+', ' ').split()
        Write-Log "[ImageList] Parsing line: '$line' -> words count=$($words.Count)"
        if ($words.Count -lt 3) {
            Write-Log "[ImageList] Skipping line with insufficient words"
            continue
        }
        $containerImage = [ContainerImage]@{
            ImageId    = $words[2]
            Repository = $words[0]
            Tag        = $words[1]
            Node       = "$hostname"
            Size       = $words[$words.Count - 2] + $words[$words.Count - 1]
        }
        Write-Log "[ImageList] Parsed image: Repository='$($words[0])' Tag='$($words[1])' ImageId='$($words[2])'"
        $linuxContainerImages += $containerImage
    }
    Write-Log "[ImageList] Total parsed images before K8s filter = $($linuxContainerImages.Count)"
    if ($IncludeK8sImages -eq $false) {
        $linuxContainerImages =
        Get-FilteredImages -ContainerImages $linuxContainerImages -ContainerImagesToBeCleaned $KubernetesImages
        Write-Log "[ImageList] Total images after K8s filter = $($linuxContainerImages.Count)"
    }

    # Filter addon images and deduplicate
    $linuxContainerImages = Invoke-ImageFilteringAndDeduplication -ContainerImages $linuxContainerImages -ExcludeAddonImages $ExcludeAddonImages -NodeType 'Linux'

    return $linuxContainerImages
}

function Get-ContainerImagesOnWindowsNode([bool]$IncludeK8sImages = $false, [bool]$ExcludeAddonImages = $false) {
    $output = &$crictlExe --config $kubeBinPath\crictl.yaml images 2> $null
    $node = $env:ComputerName.ToLower()

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

        # Filter addon images and deduplicate
        $windowsContainerImages = Invoke-ImageFilteringAndDeduplication -ContainerImages $windowsContainerImages -ExcludeAddonImages $ExcludeAddonImages -NodeType 'Windows'
    }
    return $windowsContainerImages
}


function Invoke-ImageFilteringAndDeduplication {
    param(
        [Parameter(Mandatory = $true, HelpMessage = 'Array of container images to process.')]
        [AllowNull()]
        [array]$ContainerImages,

        [Parameter(Mandatory = $true, HelpMessage = 'Set to $true to exclude addon images.')]
        [bool]$ExcludeAddonImages,

        [Parameter(Mandatory = $true, HelpMessage = 'Type of node: Linux or Windows.')]
        [ValidateSet('Linux', 'Windows')]
        [string]$NodeType
    )

    # Handle null input
    if ($null -eq $ContainerImages) {
        Write-Log "[$NodeType`Node] No images available to filter"
        $ContainerImages = @()
        return $ContainerImages
    }

    # Filter addon images from excluded namespaces
    $ContainerImages = Filter-AddonImagesFromList -ContainerImages $ContainerImages -ExcludeAddonImages $ExcludeAddonImages -NodeType $NodeType

    # Ensure we have an array (even if empty) before deduplication
    if ($null -eq $ContainerImages) {
        Write-Log "[$NodeType`Node] Filter returned null, initializing empty array"
        $ContainerImages = @()
        return $ContainerImages
    }

    # Deduplicate images with same ImageID (prefer tagged over <none>) - only if there are images
    if ($ContainerImages.Count -gt 0) {
        $ContainerImages = Remove-DuplicateImages -ContainerImages $ContainerImages -NodeType $NodeType
    } else {
        Write-Log "[$NodeType`Node] No images to deduplicate"
    }

    return $ContainerImages
}

function Get-PushedContainerImages() {
    $setupFilePath = Get-SetupConfigFilePath
    $enableAddons = Get-ConfigValue -Path $setupFilePath -Key 'EnabledAddons'
    $isRegistryAddonEnabled = $enableAddons | Select-Object -ExpandProperty Name | Where-Object { $_ -eq 'registry' }
    if (!$isRegistryAddonEnabled) {
        return
    }

    $registryName = $(Get-RegistriesFromSetupJson) | Where-Object { $_ -match 'k2s.registry.local' }
    # $auth = Get-RegistryAuthToken $registryName
    # if (!$auth) {
    #     Write-Error "Can't find authentication token for $registryName."
    #     return
    # }

    $isNodePort = $registryName -match ':'

    if (!$isNodePort) {
        $catalog = $(curl.exe --noproxy $registryName --retry 3 --retry-all-errors -k -X GET https://$registryName/v2/_catalog) 2> $null | Out-String | ConvertFrom-Json
    }
    else {
        $catalog = $(curl.exe --noproxy $registryName --retry 3 --retry-all-errors -X GET http://$registryName/v2/_catalog) 2> $null | Out-String | ConvertFrom-Json
    }
    $images = $catalog.psobject.properties['repositories'].value

    $pushedContainerImages = @()
    foreach ($image in $images) {
        if (!$isNodePort) {
            $imageWithTags = curl.exe --noproxy $registryName --retry 3 --retry-all-errors -k -X GET https://$registryName/v2/$image/tags/list 2> $null | Out-String | ConvertFrom-Json
        }
        else {
            $imageWithTags = curl.exe --noproxy $registryName --retry 3 --retry-all-errors -X GET http://$registryName/v2/$image/tags/list 2> $null | Out-String | ConvertFrom-Json
        }
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

function Remove-Image([ContainerImage]$ContainerImage, [switch]$Force) {
    $output = ''
    $imageId = $ContainerImage.ImageId

    if ($ContainerImage.Node -eq $env:ComputerName.ToLower()) {
        if ($Force) {
            # Stop and remove any containers using this image first (including terminated ones)
            $containersOutput = $(&$crictlExe --config $kubeBinPath\crictl.yaml ps -a -q --image $imageId 2>&1)
            if ($containersOutput) {
                foreach ($containerId in $containersOutput) {
                    if (![string]::IsNullOrWhiteSpace($containerId)) {
                        Write-Log "[ImageRm] Stopping and removing container $containerId that uses image $imageId"
                        $(&$crictlExe --config $kubeBinPath\crictl.yaml stop $containerId 2>&1) | Out-Null
                        $(&$crictlExe --config $kubeBinPath\crictl.yaml rm $containerId 2>&1) | Out-Null
                    }
                }
            }
            # Also remove any pod sandboxes that might be holding references
            $podsOutput = $(&$crictlExe --config $kubeBinPath\crictl.yaml pods -q 2>&1)
            if ($podsOutput) {
                foreach ($podId in $podsOutput) {
                    if (![string]::IsNullOrWhiteSpace($podId)) {
                        # Check if this pod has containers using our image
                        $podContainers = $(&$crictlExe --config $kubeBinPath\crictl.yaml ps -a -q -p $podId --image $imageId 2>&1)
                        if ($podContainers) {
                            Write-Log "[ImageRm] Stopping and removing pod $podId that has containers using image $imageId"
                            $(&$crictlExe --config $kubeBinPath\crictl.yaml stopp $podId 2>&1) | Out-Null
                            $(&$crictlExe --config $kubeBinPath\crictl.yaml rmp $podId 2>&1) | Out-Null
                        }
                    }
                }
            }
        }
        $output = $(&$crictlExe --config $kubeBinPath\crictl.yaml rmi $imageId 2>&1)
    }
    else {
        if ($Force) {
            # Stop and remove any containers using this image first (including terminated ones)
            $containersResult = Invoke-CmdOnControlPlaneViaSSHKey "sudo crictl ps -a -q --image $imageId"
            if ($containersResult.Output) {
                foreach ($containerId in $containersResult.Output) {
                    if (![string]::IsNullOrWhiteSpace($containerId)) {
                        Write-Log "[ImageRm] Stopping and removing container $containerId that uses image $imageId"
                        Invoke-CmdOnControlPlaneViaSSHKey "sudo crictl stop $containerId" | Out-Null
                        Invoke-CmdOnControlPlaneViaSSHKey "sudo crictl rm $containerId" | Out-Null
                    }
                }
            }
            # Also remove any pod sandboxes that might be holding references
            $podsResult = Invoke-CmdOnControlPlaneViaSSHKey "sudo crictl pods -q"
            if ($podsResult.Output) {
                foreach ($podId in $podsResult.Output) {
                    if (![string]::IsNullOrWhiteSpace($podId)) {
                        # Check if this pod has containers using our image
                        $podContainersResult = Invoke-CmdOnControlPlaneViaSSHKey "sudo crictl ps -a -q -p $podId --image $imageId"
                        if ($podContainersResult.Output) {
                            Write-Log "[ImageRm] Stopping and removing pod $podId that has containers using image $imageId"
                            Invoke-CmdOnControlPlaneViaSSHKey "sudo crictl stopp $podId" | Out-Null
                            Invoke-CmdOnControlPlaneViaSSHKey "sudo crictl rmp $podId" | Out-Null
                        }
                    }
                }
            }
        }
        $output = (Invoke-CmdOnControlPlaneViaSSHKey "sudo crictl rmi $imageId").Output
    }

    $errorString = Get-ErrorMessageIfImageDeletionFailed -Output $output

    return $errorString
}

function Remove-PushedImage($name, $tag) {
    $registryName = $(Get-RegistriesFromSetupJson) | Where-Object { $_ -match 'k2s.registry.*' }
    # $auth = Get-RegistryAuthToken $registryName
    # if (!$auth) {
    #     Write-Error "Can't find authentication token for $registryName."
    #     return
    # }

    if ($name.Contains("$registryName/")) {
        $name = $name.Replace("$registryName/", '')
    }

    $status = $null
    $statusDescription = $null

    $isNodePort = $registryName -match ':'
    if (!$isNodePort) {
        $headRequest = "curl.exe -m 10 --noproxy $registryName --retry 3 --retry-connrefused -k -I https://$registryName/v2/$name/manifests/$tag $concatenatedHeadersString -v 2>&1"
    }
    else {
        $headRequest = "curl.exe -m 10 --noproxy $registryName --retry 3 --retry-connrefused -I http://$registryName/v2/$name/manifests/$tag $concatenatedHeadersString -v 2>&1"
    }

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
        Write-Output "Successfully retrieved digest for $imageName from $registryName"
    }
    else {
        Write-Error "An error occurred while getting digest. HTTP Status Code: $status $statusDescription"
    }


    $lineWithDigest = $headResponse | Select-String 'Docker-Content-Digest:' | Select-Object -ExpandProperty Line -First 1
    $match = Select-String 'Docker-Content-Digest: (.*)' -InputObject $lineWithDigest
    $digest = $match.Matches.Groups[1].Value

    if (!$isNodePort) {
        $deleteRequest = "curl.exe -m 10 -k -I --noproxy $registryName --retry 3 --retry-connrefused -X DELETE https://$registryName/v2/$name/manifests/$digest $concatenatedHeadersString -v 2>&1"
    }
    else {
        $deleteRequest = "curl.exe -m 10 -I --noproxy $registryName --retry 3 --retry-connrefused -X DELETE http://$registryName/v2/$name/manifests/$digest $concatenatedHeadersString -v 2>&1"
    }
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
    $authJson = (Invoke-CmdOnControlPlaneViaSSHKey 'sudo cat /root/.config/containers/auth.json').Output | Out-String
    $dockerConfig = $authJson | ConvertFrom-Json
    $dockerAuth = $dockerConfig.psobject.properties['auths'].value
    $authk2s = $dockerAuth.psobject.properties["$registryName"].value
    $auth = $authk2s.psobject.properties['auth'].value
    return $auth
}

function Get-ContainerImagesInk2s([bool]$IncludeK8sImages = $false, [bool]$ExcludeAddonImages = $false) {
    $linuxContainerImages = Get-ContainerImagesOnLinuxNode -IncludeK8sImages $IncludeK8sImages -ExcludeAddonImages $ExcludeAddonImages
    Write-Log "[ImageFilter] Found $($linuxContainerImages.Count) Linux image(s)"
    $linuxContainerImages | ForEach-Object { Write-Log "[ImageFilter]   Linux: $($_.Repository):$($_.Tag) (ID: $($_.ImageId), Node: $($_.Node), Size: $($_.Size))" }

    $windowsContainerImages = Get-ContainerImagesOnWindowsNode -IncludeK8sImages $IncludeK8sImages -ExcludeAddonImages $ExcludeAddonImages
    Write-Log "[ImageFilter] Found $($windowsContainerImages.Count) Windows image(s)"
    $windowsContainerImages | ForEach-Object { Write-Log "[ImageFilter]   Windows: $($_.Repository):$($_.Tag) (ID: $($_.ImageId), Node: $($_.Node), Size: $($_.Size))" }
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
        Write-Log "Successfully deleted image $imageName from $node"
        return 0
    }
    else {
        Write-Log "Failed to delete image $imageName from $node. Reason: $ErrorMessage"
        return 1
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
        # If the Dockerfile ends with PreCompile, we set the PreCompile flag to true
        if ($Dockerfile -like '*PreCompile') {
            $PreCompile = $True
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

function Wait-UntilServiceIsRunning {
    param (
        $Name = $(throw 'Argument missing: ServiceName')
    )

    # ensure service is running
    $expectedServiceStatus = 'SERVICE_RUNNING'
    Write-Log "Waiting until service '$Name' has status '$expectedServiceStatus'"
    $retryNumber = 0
    $maxAmountOfRetries = 3
    $waitTimeInSeconds = 2
    $serviceIsRunning = $false
    while ($retryNumber -lt $maxAmountOfRetries) {
        $serviceStatus = (&$kubeBinPath\nssm status $Name)
        if ($serviceStatus -eq "$expectedServiceStatus") {
            $serviceIsRunning = $true
            break;
        }
        $retryNumber++
        Start-Sleep -Seconds $waitTimeInSeconds
        $totalWaitingTime = $waitTimeInSeconds * $retryNumber
        Write-Log "Waiting since $totalWaitingTime seconds for service '$Name' to be in status '$expectedServiceStatus' (current status: $serviceStatus)"
    }
    if (!$serviceIsRunning) {
        throw "Service '$Name' is not running."
    }
    Write-Log "Service '$Name' has status '$expectedServiceStatus'"
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
        Wait-UntilServiceIsRunning -Name 'docker'
        $shouldStopDocker = $true
    }

    $imageFullName = "${ImageName}:$ImageTag"

    Write-Log "Building Windows image $imageFullName" -Console
    if ($BuildArgsString -ne '') {
        $cmd = "$dockerExe build ""$InputFolder"" -f ""$Dockerfile"" --force-rm $NoCacheFlag -t $imageFullName $BuildArgsString"
    }
    else {
        $cmd = "$dockerExe build ""$InputFolder"" -f ""$Dockerfile"" --force-rm $NoCacheFlag -t $imageFullName"
    }
    Write-Log "Build cmd: $cmd"
    & cmd.exe /c $cmd *>&1 | Where-Object { (-not(($_ -is [System.Management.Automation.ErrorRecord])) -or (($_ -is [System.Management.Automation.ErrorRecord]) -and -not($_ -match 'System.Management.Automation.RemoteException'))) } | ForEach-Object { Write-Log $_ }
    
    if ($LASTEXITCODE -ne 0) { throw "error while creating image with 'docker build' on Windows. Error code returned was $LastExitCode" }

    Write-Log "Output of checking if the image $imageFullName is now available in docker:"
    $dockerListOutput = &$dockerExe image ls $ImageName -a --format "table {{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}" 2>&1
    $dockerListOutput | ForEach-Object { Write-Log $_ }

    $exportedImageFullFileName = $env:TEMP + '\BuiltImage.tar'
    if (Test-Path($exportedImageFullFileName)) {
        Remove-Item $exportedImageFullFileName -Force
    }

    Write-Log "Saving image $imageFullName temporarily as $exportedImageFullFileName to import it afterwards into containerd..."
    &$dockerExe save -o "$exportedImageFullFileName" $imageFullName
    if (!$?) { throw "error while saving built image '$imageFullName' with 'docker save' on Windows. Error code returned was $LastExitCode" }
    Write-Log '...saved.'

    Write-Log "Importing image $imageFullName from $exportedImageFullFileName into containerd..."
    &$nerdctlExe -n k8s.io load -i "$exportedImageFullFileName"
    if (!$?) { throw "error while importing built image '$imageFullName' with 'nerdctl.exe load' on Windows. Error code returned was $LastExitCode" }
    Write-Log '...imported'

    Write-Log "Removing temporarily created file $exportedImageFullFileName..."
    Remove-Item $exportedImageFullFileName -Force
    Write-Log '...removed'

    $imageList = &$ctrExe -n="k8s.io" images list 2>&1 | Out-string

    if (!$imageList.Contains($imageFullName)) {
        throw "The built image '$imageFullName' was not imported in the containerd's local repository."
    }
    Write-Log "The built image '$imageFullName' is available in the containerd's local repository."

    if ($shouldStopDocker) {
        Write-Log 'Stopping docker backend...'
        Stop-Service docker
    }
}

function Set-DockerToExperimental {
    $env:DOCKER_CLI_EXPERIMENTAL = 'enabled'

    nssm restart docker

    if ($LASTEXITCODE -ne 0) {
        throw 'error while restarting Docker'
    }
}

function New-DockerManifest {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Tag = $(throw 'Tag not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $AmendTag = $(throw 'AmendTag not specified'),
        [parameter(Mandatory = $false, HelpMessage = 'If set to true, insecure registries like local registries are allowed.')]
        [switch] $AllowInsecureRegistries
    )
    if ($AllowInsecureRegistries -eq $true) {
        &$dockerExe manifest create --insecure $Tag --amend $AmendTag
    }
    else {
        &$dockerExe manifest create $Tag --amend $AmendTag
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
        $AmendTag = $(throw 'AmendTag not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $OS = $(throw 'OS not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $Arch = $(throw 'Arch not specified'),
        [string]
        $OSVersion = $(throw 'OSVersion not specified')
    )
    &$dockerExe manifest annotate --os $OS --arch $Arch --os-version $OSVersion $Tag $AmendTag

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
        &$dockerExe manifest push --insecure $Tag
    }
    else {
        &$dockerExe manifest push $Tag
    }

    if ($LASTEXITCODE -ne 0) {
        throw 'error pushing manifest'
    }
}


function Get-ImagesFromNamespaces {
    param(
        [Parameter(Mandatory = $true, HelpMessage = 'Array of namespaces to query for images.')]
        [string[]]$Namespaces,

        [Parameter(Mandatory = $true, HelpMessage = 'Log prefix for filtering context (e.g., "addon", "user").')]
        [string]$LogPrefix
    )

    if ($Namespaces.Count -eq 0) {
        Write-Log "[ImageFilter] No $LogPrefix namespaces to query"
        return @()
    }

    $kubectlExe = "$kubeBinPath\kube\kubectl.exe"
    $collectedImages = @()

    foreach ($namespace in $Namespaces) {
        try {
            # Query images from namespace using jsonpath for efficiency
            $output = & $kubectlExe get pods -n $namespace -o jsonpath="{.items[*].spec.containers[*].image}" 2>$null

            if ($output) {
                # Split by whitespace and filter empty strings
                $images = $output -split '\s+' | Where-Object { $_ -ne '' }

                if ($images.Count -gt 0) {
                    Write-Log "[ImageFilter]   Namespace '$namespace': found $($images.Count) image(s)"
                    $collectedImages += $images
                }
            }
        }
        catch {
            Write-Log "[ImageFilter]   Warning: Failed to query namespace '$namespace': $_"
        }
    }

    # Return unique images
    $uniqueImages = $collectedImages | Select-Object -Unique
    Write-Log "[ImageFilter] Total unique $LogPrefix images: $($uniqueImages.Count)"

    return $uniqueImages
}

function Get-ImagesFromExcludedNamespaces {
    # Get excluded namespaces from config
    $excludedNamespacesString = $rootConfig.backup.excludednamespaces

    if ([string]::IsNullOrWhiteSpace($excludedNamespacesString)) {
        Write-Log '[ImageFilter] No excluded namespaces configured'
        return @()
    }

    # Parse comma-separated namespace list
    $excludedNamespaces = $excludedNamespacesString -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

    Write-Log "[ImageFilter] Excluding images from $($excludedNamespaces.Count) addon/infrastructure namespaces"

    # Use common helper to get images
    return Get-ImagesFromNamespaces -Namespaces $excludedNamespaces -LogPrefix 'addon'
}

function Get-ImagesFromUserNamespaces {
    $kubectlExe = "$kubeBinPath\kube\kubectl.exe"

    # Get excluded namespaces from config
    $excludedNamespacesString = $rootConfig.backup.excludednamespaces
    # Parse excluded namespaces
    $excludedNamespaces = @()
    if (-not [string]::IsNullOrWhiteSpace($excludedNamespacesString)) {
        $excludedNamespaces = $excludedNamespacesString -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    }

    # Get all namespaces
    try {
        $allNamespacesOutput = & $kubectlExe get namespaces -o jsonpath="{.items[*].metadata.name}" 2>$null

        if (-not $allNamespacesOutput) {
            Write-Log "[ImageFilter] No namespaces found in cluster"
            return @()
        }

        # Parse all namespaces
        $allNamespaces = $allNamespacesOutput -split '\s+' | Where-Object { $_ -ne '' }

        # Filter out excluded namespaces to get user namespaces
        $userNamespaces = $allNamespaces | Where-Object { $excludedNamespaces -notcontains $_ }

        Write-Log "[ImageFilter] Found $($userNamespaces.Count) user namespace(s) (excluding $($excludedNamespaces.Count) addon/system namespaces)"

        if ($userNamespaces.Count -eq 0) {
            Write-Log "[ImageFilter] No user namespaces found"
            return @()
        }

        # Use common helper to get images from user namespaces
        return Get-ImagesFromNamespaces -Namespaces $userNamespaces -LogPrefix 'user workload'
    }
    catch {
        Write-Log "[ImageFilter] Error getting user namespace images: $_" -Console
        return @()
    }
}

function Get-SharedImages {
    param(
        [string[]]$AddonImages,
        [string[]]$UserImages
    )

    $shared = @()
    if ($UserImages.Count -eq 0) {
        return $shared
    }
    foreach ($addonImg in $AddonImages) {
        if ($UserImages -contains $addonImg) {
            $shared += $addonImg
        }
    }
    if ($shared.Count -gt 0) {
        Write-Log "[ImageFilter] Found $($shared.Count) image(s) shared between addon and user namespaces - keeping them in backup:"
        $shared | ForEach-Object { Write-Log "[ImageFilter]   Shared: $_" }
    }
    return $shared
}

function Get-AddonOnlyRepositories {
    param([string[]]$AddonOnlyImages)

    return $AddonOnlyImages | ForEach-Object {
        if ($_ -match '^(.+):') { $Matches[1] } else { $_ }
    } | Select-Object -Unique
}

function Check-IsUserOrSharedImage {
    param(
        [object]$Image,
        [string[]]$AddonOnlyImages,
        [string[]]$AddonOnlyRepositories
    )

    # For <none> tags, match by repository only
    if ($Image.Tag -eq '<none>') {
        return $AddonOnlyRepositories -notcontains $Image.Repository
    }

    # For proper tags, match full image name
    $imageFullName = "$($Image.Repository):$($Image.Tag)"

    # Check if this image is in the addon-only list (not shared with users)
    return -not ($AddonOnlyImages -contains $imageFullName)
}

function Filter-AddonImagesFromList {
    param(
        [Parameter(Mandatory = $true, HelpMessage = 'Array of container images to filter.')]
        [AllowNull()]
        [AllowEmptyCollection()]
        [array]$ContainerImages,

        [Parameter(Mandatory = $true, HelpMessage = 'Set to $true to exclude addon images from the list.')]
        [bool]$ExcludeAddonImages,

        [Parameter(Mandatory = $true, HelpMessage = 'Node type: Linux or Windows.')]
        [ValidateSet('Linux', 'Windows')]
        [string]$NodeType
    )

    # Handle null or empty input
    if ($null -eq $ContainerImages -or $ContainerImages.Count -eq 0) {
        Write-Log "[$NodeType`Node] No images to filter (null or empty)"
        return @()
    }

    if ($ExcludeAddonImages -eq $false) {
        Write-Log "[$NodeType`Node] ExcludeAddonImages is FALSE, skipping addon filter"
        return $ContainerImages
    }

    Write-Log "[ImageFilter] Filtering addon images from $NodeType node..."

    # Get addon and user images
    $addonImageStrings = Get-ImagesFromExcludedNamespaces
    if ($addonImageStrings.Count -eq 0) {
        Write-Log "[ImageFilter] No addon images to exclude, returning all images"
        return $ContainerImages
    }

    $userImageStrings = Get-ImagesFromUserNamespaces
    Write-Log "[ImageFilter] Found $($addonImageStrings.Count) addon image(s) and $($userImageStrings.Count) user workload image(s)"

    # Identify shared images (used by both addons and users)
    $sharedImages = Get-SharedImages -AddonImages $addonImageStrings -UserImages $userImageStrings

    # Only exclude addon images that are NOT used by user workloads
    $addonOnlyImages = $addonImageStrings | Where-Object { $sharedImages -notcontains $_ }
    Write-Log "[ImageFilter] Excluding $($addonOnlyImages.Count) addon-only image(s) (not used by user workloads)"

    # Build lookup structures for efficient filtering
    $addonOnlyRepositories = Get-AddonOnlyRepositories -AddonOnlyImages $addonOnlyImages

    # Filter images
    $filteredImages = $ContainerImages | Where-Object {
        Check-IsUserOrSharedImage -Image $_ -AddonOnlyImages $addonOnlyImages -AddonOnlyRepositories $addonOnlyRepositories
    }

    Write-Log "[ImageFilter] After addon filtering: $($filteredImages.Count) image(s) remaining (user workload + shared images)"
    return $filteredImages
}

function Remove-DuplicateImages {
    param(
        [Parameter(Mandatory = $true, HelpMessage = 'Array of container images to deduplicate.')]
        [array]$ContainerImages,

        [Parameter(Mandatory = $true, HelpMessage = 'Type of node: Linux or Windows.')]
        [string]$NodeType
    )

    # Deduplicate images with same ImageID (prefer tagged over <none>)
    $uniqueImages = @{}
    foreach ($image in $ContainerImages) {
        $imageId = $image.ImageId

        if ($uniqueImages.ContainsKey($imageId)) {
            # If existing entry has <none> tag and new one has real tag, replace it
            if ($uniqueImages[$imageId].Tag -eq '<none>' -and $image.Tag -ne '<none>') {
                $uniqueImages[$imageId] = $image
                Write-Log "[$NodeType`Node] Replaced <none> tag with proper tag for ImageID: $imageId"
            }
            # If both are <none> or both are proper tags, keep first
        }
        else {
            # Only add if not <none> tag OR if it's the only version of this ImageID
            $uniqueImages[$imageId] = $image
        }
    }

    # Final pass: remove any remaining <none> tagged images
    $deduplicatedImages = $uniqueImages.Values | Where-Object { $_.Tag -ne '<none>' } | Sort-Object Repository, Tag

    # Ensure we always return an array, even if empty
    if ($null -eq $deduplicatedImages) {
        Write-Log "[$NodeType`Node] All images were <none> tagged or list is empty, returning empty array"
        return @()
    }

    return $deduplicatedImages
}

Export-ModuleMember -Function Get-ContainerImagesInk2s, `
    Remove-Image, `
    Get-PushedContainerImages, `
    Remove-PushedImage, `
    Show-ImageDeletionStatus, `
    Get-ContainerImagesOnLinuxNode, `
    Get-ContainerImagesOnWindowsNode, `
    Write-KubernetesImagesIntoJson, `
    Get-BuildArgs, `
    Get-DockerfileAbsolutePathAndPreCompileFlag, `
    New-WindowsImage, `
    Set-DockerToExperimental, `
    New-DockerManifest, `
    New-DockerManifestAnnotation, `
    Push-DockerManifest
