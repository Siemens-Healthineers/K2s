# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$configModule = "$PSScriptRoot\..\..\..\k2s.infra.module\config\config.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\k2s.infra.module\log\log.module.psm1"
Import-Module $logModule, $pathModule, $configModule

#Import all modules under artifacts for downloading
Get-ChildItem -Path "$PSScriptRoot\artifacts\" -Filter '*.psm1' -Recurse | Where-Object { $_.FullName -ne "$PSCommandPath" } | Foreach-Object { Import-Module $_.FullName }

$kubePath = Get-KubePath
$kubeBinPath = Get-KubeBinPath

# download
$downloadsDirectory = "$kubeBinPath\downloads" #e.g. c:\k\bin\downloads

# windows node artifacts
$windowsNodeArtifactsDownloadsDirectory = "$downloadsDirectory\windowsnode" #e.g. c:\k\bin\downloads\windowsnode

# used for install
$windowsNodeArtifactsDirectory = "$kubeBinPath\windowsnode" #e.g. c:\k\bin\windowsnode

# windows node artifacts zip file
$windowsNodeArtifactsZipFileName = 'WindowsNodeArtifacts.zip'
$windowsNodeArtifactsZipFilePath = "$kubeBinPath\$windowsNodeArtifactsZipFileName"

# Windows images
$windowsNode_ImagesDirectory = "images"


$ErrorActionPreference = 'Stop'

function Get-StringFromText([string]$text, [string]$searchPattern) {
    [regex]$rx = $searchPattern
    $foundValue = ""
    $result = $rx.match($text)
    if ($result.Success -and $result.Groups.Count -gt 1) {
        $foundValue = $result.Groups[1].Value
    }
    return $foundValue
}

function Invoke-DownloadWindowsImages($downloadsBaseDirectory, $Proxy) {
    $windowsImagesDownloadsDirectory = "$downloadsBaseDirectory\$windowsNode_ImagesDirectory"
    $tomlFilePath = "$kubePath\cfg\containerd\config.toml"
    if (!(Test-Path -Path $tomlFilePath)) {
        throw "The expected file '$tomlFilePath' is not available"
    }

    $tomlContent = Get-Content -Path "$tomlFilePath"

    $sandboxImageName = Get-StringFromText $tomlContent 'sandbox_image = "([^"]*)"'

    if ($sandboxImageName -eq "") {
        throw "The sandbox image name and/or the username and/or the password gathered from the file '$tomlFilePath' is empty"
    }

    $nerdctlExe = "$kubeBinPath\nerdctl.exe"
    $ctrExe = Get-CtrExePath

    Write-Log "Create folder '$windowsImagesDownloadsDirectory'"
    mkdir $windowsImagesDownloadsDirectory | Out-Null
    Write-Log "Pull image '$sandboxImageName' from repository using proxy:$Proxy"

    $initialized = $false
    $imagePulledSuccessfully = $false

    $HttpProxyVariableOriginalValue = $env:HTTP_PROXY
    $HttpsProxyVariableOriginalValue = $env:HTTPS_PROXY
    try {
        $env:HTTP_PROXY=$Proxy
        $env:HTTPS_PROXY=$Proxy

        $retryNumber = 0
        $maxAmountOfRetries = 3
        $waitTimeInSeconds = 2

        # check whether containerd is initialized and connection works
        while ($retryNumber -lt $maxAmountOfRetries) {
            try {
                &$nerdctlExe -n="k8s.io" image ls | Out-Null
                if (!$?) {
                    throw
                }
                $initialized = $true
                break;
            }
            catch {
                Write-Log "Containerd is not initialized yet. Waiting $waitTimeInSeconds seconds to try again"
                $retryNumber++
                Start-Sleep -Seconds $waitTimeInSeconds
            }
        }
        if (!$initialized) {
            Write-Log "Containerd is not initialized yet after $maxAmountOfRetries tries."
        }

        # Now really pull image and ignore errors from ctr
        $ErrorActionPreference = 'Continue'
        &$nerdctlExe -n="k8s.io" pull $sandboxImageName --all-platforms 2>&1 | Out-Null
        $images = &$ctrExe -n="k8s.io" image ls 2>&1 | Out-String

        if ($images.Contains($sandboxImageName)) {
            $imagePulledSuccessfully = $true
        }
    }
    finally {
        $env:HTTP_PROXY=$HttpProxyVariableOriginalValue
        $env:HTTPS_PROXY=$HttpsProxyVariableOriginalValue
    }

    $ErrorActionPreference = 'Stop'

    if ($imagePulledSuccessfully) {
        $tarFileName = $sandboxImageName.Replace(":", "_").Replace("/", "__") + ".tar"
        $tarFilePath = "$windowsImagesDownloadsDirectory\$tarFileName"

        if (Test-Path -Path $tarFilePath -PathType 'Leaf' -ErrorAction Stop) {
            Write-Log "File '$tarFilePath' already exists. Deleting it"
            Remove-Item -Path $tarFilePath -Force -ErrorAction Stop
            Write-Log "  done"
        }

        Write-Log "Export image '$sandboxImageName' to '$tarFilePath'"
        &$nerdctlExe -n="k8s.io" save -o `"$tarFilePath`" "$sandboxImageName" --all-platforms
        if (!$?) {
            throw "The image '$sandboxImageName' could not be exported"
        }
        Write-Log "Image '$sandboxImageName' available as '$tarFilePath'"
    } else {
        $filePath = "$windowsImagesDownloadsDirectory\TheImageCouldNotBePulled.txt"
        Write-Log "The image '$sandboxImageName' could not be pulled. The placeholder file '$filePath' will be written instead."
        New-Item -Path $filePath | Out-Null
    }
}

function Invoke-DeployWindowsImages($windowsNodeArtifactsDirectory) {
    $windowsImagesArtifactsDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_ImagesDirectory"
    if (!(Test-Path "$windowsImagesArtifactsDirectory")) {
        throw "Directory '$windowsImagesArtifactsDirectory' does not exist"
    }

    $nerdctlExe = "$kubeBinPath\nerdctl.exe"
    $fileSearchPattern = "$windowsImagesArtifactsDirectory\*.tar"
    $files = Get-ChildItem -Path "$fileSearchPattern"
    $amountOfFiles = $files.Count
    Write-Log "Amount of images found that matches the search pattern '$fileSearchPattern': $amountOfFiles"
    $fileIndex = 1

    foreach ($file in $files){
        $fileFullName = $file.FullName
        Write-Log "Import image from file '$fileFullName'... ($fileIndex of $amountOfFiles)"
        &$nerdctlExe -n k8s.io load -i `"$file`"
        if (!$?) {
            throw "The file '$fileFullName' could not be imported"
        }
        Write-Log "  done"
        $fileIndex++
    }
}

function Invoke-DownloadWindowsNodeArtifacts {
    Param(
        [parameter(Mandatory = $true, HelpMessage = 'Kubernetes version to use')]
        [string] $KubernetesVersion,
        [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
        [string] $Proxy = '',
        [parameter(Mandatory = $false, HelpMessage = 'The path to local builds of Kubernetes binaries')]
        [string] $K8sBinsPath = ''
    )

    if (Test-Path($windowsNodeArtifactsDownloadsDirectory)) {
        Write-Log "Remove content of folder '$windowsNodeArtifactsDownloadsDirectory'"
        Remove-Item "$windowsNodeArtifactsDownloadsDirectory\*" -Recurse -Force
    } else {
        Write-Log "Create folder '$windowsNodeArtifactsDownloadsDirectory'"
        mkdir $windowsNodeArtifactsDownloadsDirectory | Out-Null
    }

    Write-Log "Start downloading artifacts for the Windows node"

    $downloadsBaseDirectory = "$windowsNodeArtifactsDownloadsDirectory"
    if (!(Test-Path $downloadsBaseDirectory)) {
        Write-Log "Create folder '$downloadsBaseDirectory'"
        New-Item -Force -Path $downloadsBaseDirectory -ItemType Directory
    }

    if (!(Test-Path($windowsNodeArtifactsDirectory))) {
        mkdir $windowsNodeArtifactsDirectory | Out-Null
    }

    # NSSM
    Invoke-DownloadNssmArtifacts $downloadsBaseDirectory $Proxy $windowsNodeArtifactsDirectory

    # DOCKER
    Invoke-DownloadDockerArtifacts $downloadsBaseDirectory $Proxy $windowsNodeArtifactsDirectory

    # CONTAINERD
    Invoke-DownloadContainerdArtifacts $downloadsBaseDirectory $Proxy $windowsNodeArtifactsDirectory
    Invoke-DownloadCrictlArtifacts $downloadsBaseDirectory $Proxy $windowsNodeArtifactsDirectory
    Invoke-DownloadNerdctlArtifacts $downloadsBaseDirectory $Proxy $windowsNodeArtifactsDirectory

    # DNSPROXY
    Invoke-DownloadDnsProxyArtifacts $downloadsBaseDirectory $Proxy

    # FLANNEL
    Invoke-DownloadFlannelArtifacts $downloadsBaseDirectory $Proxy
    Invoke-DownloadCniPlugins $downloadsBaseDirectory $Proxy
    Invoke-DownloadCniFlannelArtifacts $downloadsBaseDirectory $Proxy

    # KUBETOOLS
    Invoke-DownloadKubetoolsArtifacts $downloadsBaseDirectory $KubernetesVersion $Proxy $K8sBinsPath

    # WINDOWS EXPORTER
    Invoke-DownloadWindowsExporterArtifacts $downloadsBaseDirectory $Proxy

    #YAML TOOLS
    Invoke-DownloadYamlArtifacts $downloadsBaseDirectory $Proxy $windowsNodeArtifactsDirectory

    #PUTTY TOOLS
    Invoke-DownloadPuttyArtifacts $downloadsBaseDirectory $Proxy

    #START OF DEPLOYMENT OF DOWNLOADED ARTIFACTS
    # NSSM
    Invoke-DeployNssmArtifacts $windowsNodeArtifactsDirectory

    # CONTAINERD
    Invoke-DeployContainerdArtifacts $windowsNodeArtifactsDirectory
    Invoke-DeployCrictlArtifacts $windowsNodeArtifactsDirectory
    Invoke-DeployNerdctlArtifacts $windowsNodeArtifactsDirectory

    # YAML TOOLS
    Invoke-DeployYamlArtifacts $windowsNodeArtifactsDirectory

    Install-WinContainerd -Proxy $Proxy -SkipNetworkingSetup:$true -WindowsNodeArtifactsDirectory $windowsNodeArtifactsDirectory
    Invoke-DownloadWindowsImages $downloadsBaseDirectory $Proxy
    Uninstall-WinContainerd -ShallowUninstallation $true

    Write-Log 'Finished downloading artifacts for the Windows node'

    if (Test-Path($windowsNodeArtifactsZipFilePath)) {
        Write-Log "Remove already existing file '$windowsNodeArtifactsZipFilePath'"
        Remove-Item $windowsNodeArtifactsZipFilePath -Force
    }

    Write-Log 'Create compressed file with artifacts for the Windows node'
    Compress-Archive -Path "$windowsNodeArtifactsDownloadsDirectory\*" -DestinationPath "$windowsNodeArtifactsZipFilePath" -Force

    if (!(Test-Path($windowsNodeArtifactsZipFilePath))) {
        throw "The file '$windowsNodeArtifactsZipFilePath' that shall contain the artifacts for the Windows host could not be created."
    }

    Write-Log "Artifacts for the Windows host are available as '$windowsNodeArtifactsZipFilePath'"

    if (Test-Path($windowsNodeArtifactsDownloadsDirectory)) {
        Write-Log "Remove folder '$windowsNodeArtifactsDownloadsDirectory'"
        Remove-Item $windowsNodeArtifactsDownloadsDirectory -Force -Recurse
    }
}

function Invoke-DeployWinArtifacts {
    Param(
        [parameter(Mandatory = $true, HelpMessage = 'Kubernetes version to use')]
        [string] $KubernetesVersion,
        [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
        [string] $Proxy = '',
        [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
        [boolean] $DeleteFilesForOfflineInstallation = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Force the installation online. This option is needed if the files for an offline installation are available but you want to recreate them.')]
        [boolean] $ForceOnlineInstallation = $false,
        [parameter(Mandatory = $false, HelpMessage = 'The path to local builds of Kubernetes binaries')]
        [string] $K8sBinsPath = ''
    )

    $isZipFileAlreadyAvailable = Test-Path -Path "$windowsNodeArtifactsZipFilePath"
    $downloadArtifacts = ($ForceOnlineInstallation -or !$isZipFileAlreadyAvailable)

    Write-Log "Download Windows node artifacts?: $downloadArtifacts"
    Write-Log " - force online installation?: $ForceOnlineInstallation"
    Write-Log " - is file '$windowsNodeArtifactsZipFilePath' already available?: $isZipFileAlreadyAvailable"
    Write-Log " - Delete the file '$windowsNodeArtifactsZipFilePath' for offline installation? $DeleteFilesForOfflineInstallation"


    if ($downloadArtifacts) {
        if ($isZipFileAlreadyAvailable) {
            Write-Log "Remove already existing file '$windowsNodeArtifactsZipFilePath'"
            Remove-Item "$windowsNodeArtifactsZipFilePath" -Force
        }
        Write-Log "Create folder '$downloadsDirectory'"
        New-Item -Path "$downloadsDirectory" -ItemType Directory -Force -ErrorAction SilentlyContinue
        Invoke-DownloadWindowsNodeArtifacts -KubernetesVersion $KubernetesVersion -Proxy $Proxy -K8sBinsPath $K8sBinsPath
        Write-Log "Remove folder '$downloadsDirectory'"
        Remove-Item -Path "$downloadsDirectory" -Recurse -Force -ErrorAction SilentlyContinue
    }

    # expand zip file with windows node artifacts
    if (!(Test-Path($windowsNodeArtifactsZipFilePath))) {
        throw "The file '$windowsNodeArtifactsZipFilePath' that shall contain the artifacts for the Windows host does not exist."
    }

    if (Test-Path($windowsNodeArtifactsDirectory)) {
        Write-Log "Remove content of folder '$windowsNodeArtifactsDirectory'"
        Remove-Item "$windowsNodeArtifactsDirectory\*" -Recurse -Force
    } else {
        Write-Log "Create folder '$windowsNodeArtifactsDirectory'"
        mkdir $windowsNodeArtifactsDirectory -ErrorAction SilentlyContinue | Out-Null
    }

    Write-Log "Extract the artifacts from the file '$windowsNodeArtifactsZipFilePath' to the directory '$windowsNodeArtifactsDirectory'..."
    Expand-Archive -LiteralPath $windowsNodeArtifactsZipFilePath -DestinationPath $windowsNodeArtifactsDirectory
    Write-Log "  done"

    if ($DeleteFilesForOfflineInstallation) {
        Write-Log "Remove file '$windowsNodeArtifactsZipFilePath'"
        Remove-Item "$windowsNodeArtifactsZipFilePath" -Force
    } else {
        Write-Log "Leave file '$windowsNodeArtifactsZipFilePath' on file system for offline installation"
    }

    if(!$downloadArtifacts) {
        # Deploy NSSM when the artifacts are already present
        Invoke-DeployNssmArtifacts $windowsNodeArtifactsDirectory
    }
}

function Install-WinNodeArtifacts {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
        [string] $Proxy = '',
        [parameter(Mandatory = $true, HelpMessage = 'Host machine is a VM: true, Host machine is not a VM')]
        [bool] $HostVM,
        [parameter(Mandatory = $false, HelpMessage = 'Skips installation of cluster dependent tools')]
        [bool] $SkipClusterSetup = $false,
        [string] $PodSubnetworkNumber = $(throw 'Argument missing: PodSubnetworkNumber'),
        [parameter(Mandatory = $false, HelpMessage = 'The path to local builds of Kubernetes binaries')]
        [string] $K8sBinsPath = ''
    )

    Invoke-DeployDockerArtifacts $windowsNodeArtifactsDirectory

    Install-WinContainerd -Proxy "$Proxy" -SkipNetworkingSetup:$SkipClusterSetup -WindowsNodeArtifactsDirectory $windowsNodeArtifactsDirectory -PodSubnetworkNumber $PodSubnetworkNumber

    if (!($SkipClusterSetup)) {
        Invoke-DeployWindowsImages $windowsNodeArtifactsDirectory

        Invoke-DeployKubetoolsArtifacts $windowsNodeArtifactsDirectory
        if ($K8sBinsPath -ne '') {
            Copy-LocalBuildsOfKubeTools -K8sBinsPath $K8sBinsPath -Destination $(Get-KubeToolsPath)
        }

        Install-WinKubelet

        Invoke-DeployFlannelArtifacts $windowsNodeArtifactsDirectory
        Invoke-DeployCniPlugins $windowsNodeArtifactsDirectory
        Invoke-DeployCniFlannelArtifacts $windowsNodeArtifactsDirectory

        Install-WinFlannel
        Install-WinKubeProxy

        Invoke-DeployWindowsExporterArtifacts $windowsNodeArtifactsDirectory
        Install-WindowsExporter

    }

}

function Invoke-DownloadsCleanup {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
        [boolean] $DeleteFilesForOfflineInstallation = $false
    )

    if (Test-Path $windowsNodeArtifactsDownloadsDirectory) {
        Write-Log "Deleting folder '$windowsNodeArtifactsDownloadsDirectory'"
        Remove-Item $windowsNodeArtifactsDownloadsDirectory -Recurse -Force
    }

    if (Test-Path $windowsNodeArtifactsDirectory) {
        Write-Log "Deleting folder '$windowsNodeArtifactsDirectory'"
        Remove-Item $windowsNodeArtifactsDirectory -Recurse -Force
    }

    if ($DeleteFilesForOfflineInstallation) {
        Write-Log "Deleting file '$windowsNodeArtifactsZipFilePath' if existing"
        if (Test-Path $windowsNodeArtifactsZipFilePath) {
            Remove-Item $windowsNodeArtifactsZipFilePath -Force
        }
    }
}

function Get-WindowsNodeArtifactsZipFilePath {
    return $windowsNodeArtifactsZipFilePath
}

function Install-PuttyTools {
    if (!(Test-Path -Path $windowsNodeArtifactsDirectory)) {
        throw "Cannot install the putty tools. The directory '$windowsNodeArtifactsDirectory' does not exist."
    }
    Invoke-DeployPuttytoolsArtifacts $windowsNodeArtifactsDirectory
}

function Install-KubectlTool{
    if (!(Test-Path -Path $windowsNodeArtifactsDirectory)) {
        throw "Cannot install the tool 'kubectl'. The directory '$windowsNodeArtifactsDirectory' does not exist."
    }
    Invoke-DeployKubetoolKubectl $windowsNodeArtifactsDirectory
}

function Get-WindowsArtifactsDirectory {
    return $windowsNodeArtifactsDirectory
}

Export-ModuleMember Invoke-DeployWinArtifacts,
Invoke-DownloadsCleanup,
Install-WinNodeArtifacts,
Get-WindowsNodeArtifactsZipFilePath,
Install-PuttyTools,
Install-KubectlTool,
Get-WindowsArtifactsDirectory