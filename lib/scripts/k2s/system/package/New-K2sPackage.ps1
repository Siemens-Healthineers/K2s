# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of Linux VM')]
    [long]$VMMemoryStartupBytes = 3GB,
    [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for Linux VM')]
    [long]$VMProcessorCount = 6,
    [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of Linux VM')]
    [uint64]$VMDiskSize = 50GB,
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available to be used during installation')]
    [string] $Proxy = '',
    [parameter(Mandatory = $false, HelpMessage = 'Target directory')]
    [string] $TargetDirectory,
    [parameter(Mandatory = $false, HelpMessage = 'The name of the zip package (it must have the extension .zip)')]
    [string] $ZipPackageFileName,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Creates a zip package that can be used for offline installation')]
    [switch] $ForOfflineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$infraModule = "$PSScriptRoot/../../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule =    "$PSScriptRoot/../../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot/../../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log "- Proxy to be used: $Proxy"
Write-Log "- Target Directory: $TargetDirectory"
Write-Log "- Package file name: $ZipPackageFileName"

Add-type -AssemblyName System.IO.Compression

function BuildAndProvisionKubemasterBaseImage($WindowsNodeArtifactsZip, $OutputPath) {
    # Expand windows node artifacts directory.
    # Deploy putty and plink for provisioning.
    if (!(Test-Path $WindowsNodeArtifactsZip)) {
        $errMsg = "$WindowsNodeArtifactsZip not found. It will not be possible to provision base image without plink and pscp tools present in $WindowsNodeArtifactsZip."
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'build-package-failed' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }
    try {
        $windowsNodeArtifactsDirectory = "$(Split-Path -Parent $WindowsNodeArtifactsZip)\windowsnode"
        Write-Log "Extract the artifacts from the file '$WindowsNodeArtifactsZip' to the directory '$windowsNodeArtifactsDirectory'..."
        Expand-Archive -LiteralPath $windowsNodeArtifactsZip -DestinationPath $windowsNodeArtifactsDirectory -Force
        Write-Log "  done"
        # Deploy putty tools
        Write-Log "Temporarily deploying putty tools..." -Console
        Invoke-DeployPuttytoolsArtifacts $windowsNodeArtifactsDirectory
        # Provision linux node artifacts
        Write-Log 'Create and provision the base image' -Console
        $baseDirectory = $(Split-Path -Path $OutputPath)
        $rootfsPath = "$baseDirectory\$(Get-ControlPlaneOnWslRootfsFileName)"
        if (Test-Path -Path $rootfsPath) {
            Remove-Item -Path $rootfsPath -Force
            Write-Log "Deleted already existing file for WSL support '$rootfsPath'"
        } else {
            Write-Log "File for WSL support '$rootfsPath' does not exist. Nothing to delete."
        }
    
        $hostname = Get-ConfigControlPlaneNodeHostname
        $ipAddress = Get-ConfiguredIPControlPlane
        $gatewayIpAddress = Get-ConfiguredKubeSwitchIP
    
        $controlPlaneNodeCreationParams = @{
            Hostname=$hostname
            IpAddress=$ipAddress
            GatewayIpAddress=$gatewayIpAddress
            DnsServers= $(Get-DnsIpAddressesFromActivePhysicalNetworkInterfacesOnWindowsHost)
            VmImageOutputPath=$OutputPath
            Proxy=$Proxy
            VMMemoryStartupBytes=$VMMemoryStartupBytes
            VMProcessorCount=$VMProcessorCount
            VMDiskSize=$VMDiskSize
        }
        New-VmImageForControlPlaneNode @controlPlaneNodeCreationParams
    
        if (!(Test-Path -Path $OutputPath)) {
            throw "The file '$OutputPath' was not created"
        }
    

        $wslRootfsForControlPlaneNodeCreationParams = @{
            VmImageInputPath=$OutputPath
            RootfsFileOutputPath=$rootfsPath
            Proxy=$Proxy
            VMMemoryStartupBytes=$VMMemoryStartupBytes
            VMProcessorCount=$VMProcessorCount
            VMDiskSize=$VMDiskSize
        }
        New-WslRootfsForControlPlaneNode @wslRootfsForControlPlaneNodeCreationParams
    
        if (!(Test-Path -Path $rootfsPath)) {
            throw "The file '$rootfsPath' was not created"
        }
    } finally {
        Write-Log "Deleting the putty tools..." -Console
        Clear-ProvisioningArtifacts
        Remove-Item -Path "$kubeBinPath\plink.exe" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$kubeBinPath\pscp.exe" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $windowsNodeArtifactsDirectory -Force -Recurse -ErrorAction SilentlyContinue
    }
    if (!(Test-Path $outputPath)) {
        $errMsg = "The provisioned base image is unexpectedly not available as '$outputPath' after build and provisioning stage."

        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'build-package-failed' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
    
        Write-Log $errMsg -Error
        exit 1
    }
    Write-Log "Provisioned base image available as $OutputPath" -Console
}

function DownloadAndZipWindowsNodeArtifacts($outputPath) {
    Write-Log "Download and create zip file with Windows node artifacts for $outputPath with proxy $Proxy" -Console
    $kubernetesVersion = Get-DefaultK8sVersion
    try {
        Invoke-DeployWinArtifacts -KubernetesVersion $kubernetesVersion -Proxy "$Proxy" -SkipClusterSetup $true
    } finally {
        Invoke-DownloadsCleanup -DeleteFilesForOfflineInstallation $false
    }

    $pathToTest = $outputPath
    Write-Log "Windows node artifacts should be available as '$pathToTest', testing ..." -Console
    if (![string]::IsNullOrEmpty($pathToTest)) {
        if (!(Test-Path -Path $pathToTest)) {
            $errMsg = "The file '$pathToTest' that shall contain the Windows node artifacts is unexpectedly not available."
            Write-Log "Windows node artifacts should be available as '$pathToTest', throw fatal error" -Console

            if ($EncodeStructuredOutput -eq $true) {
                $err = New-Error -Code 'build-package-failed' -Message $errMsg
                Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                return
            }
        
            Write-Log $errMsg -Error
            exit 1
        }
    }

    Write-Log "Windows node artifacts available as '$outputPath'" -Console
}

function CreateZipArchive() {
    Param(
        [parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $ExclusionList,
        [parameter(Mandatory = $true)]
        [string] $BaseDirectory,
        [parameter(Mandatory = $true)]
        [string] $TargetPath
    )
    $files = Get-ChildItem -Path $BaseDirectory -Force -Recurse | ForEach-Object { $_.FullName }
    $fileStreamMode = [System.IO.FileMode]::Create
    $zipMode = [System.IO.Compression.ZipArchiveMode]::Create
    $compressionLevel = [System.IO.Compression.CompressionLevel]::Optimal

    try {
        try {
            $zipFileStream = [System.IO.File]::Open($TargetPath, $fileStreamMode)
            $zipFile = [System.IO.Compression.ZipArchive]::new($zipFileStream, $zipMode)
        }
        catch {
            Write-Log "ERROR in CreateZipArchive: $_"
            $zipFile, $zipFileStream | ForEach-Object Dispose

            if ($EncodeStructuredOutput -eq $true) {
                $err = New-Error -Code 'build-package-failed' -Message $_
                Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                return
            }
        
            Write-Log $_ -Error
            exit 1
        }

        foreach ($file in $files) {
            try {
                if ($ExclusionList.Contains($file) -or
                       ($ExclusionList | Foreach-Object { $file.StartsWith($_) }) -contains $true) {
                    Write-Log "File or directory '$file' not included because of exclusion list"
                    Continue
                }

                $relativeFilePath = $file.Replace("$BaseDirectory\", '')
                $isDirectory = (Get-Item $file) -is [System.IO.DirectoryInfo]
                if ($isDirectory) {
                    Write-Log "Adding directory '$file' into zip file..."
                    $zipFileEntry = $zipFile.CreateEntry("$relativeFilePath\")
                    Write-Log '...done.'
                }
                else {
                    $zipFileEntry = $zipFile.CreateEntry($relativeFilePath, $compressionLevel)
                    $zipFileStreamEntry = $zipFileEntry.Open()
                    Write-Log "Adding file '$file' into zip file..."
                    $sourceFileStream = [System.IO.File]::OpenRead($file)
                    $sourceFileStream.CopyTo($zipFileStreamEntry)
                    Write-Log '...done.'
                }
            }
            catch {
                Write-Error $_
            }
            finally {
                $sourceFileStream, $zipFileStreamEntry | ForEach-Object Dispose
            }
        }
    }
    finally {
        $zipFile, $zipFileStream | ForEach-Object Dispose
    }
}

$errMsg = ''
if ('' -eq $TargetDirectory) {
    $errMsg = 'The passed target directory is empty'
}
elseif (!(Test-Path -Path $TargetDirectory)) {
    $errMsg = "The passed target directory '$TargetDirectory' could not be found"
}
elseif ('' -eq $ZipPackageFileName) {
    $errMsg = 'The passed zip package name is empty'
}
elseif ($ZipPackageFileName.EndsWith('.zip') -eq $false) {
    $errMsg = "The passed zip package name '$ZipPackageFileName' does not have the extension '.zip'"
}
else {
    $setupInfo = Get-SetupInfo
    if ($null -eq $setupInfo.Error) {
        $productName = $setupInfo.Name
        $errMsg = "'$productName' is installed on your system. Please uninstall '$productName' first and try again."
    }
}

if ($errMsg -ne '') {
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code 'build-package-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$zipPackagePath = Join-Path "$TargetDirectory" "$ZipPackageFileName"

# delete eventuell already existing zip file
if (Test-Path $zipPackagePath) {
    Write-Log "Removing already existing file '$zipPackagePath'" -Console
    Remove-Item $zipPackagePath -Force
}

# create exclusion list
$kubePath = Get-KubePath
$exclusionList = @('.git', '.vscode', '.gitignore') | ForEach-Object { Join-Path $kubePath $_ }
$exclusionList += "$kubePath\k2s\cmd\k2s\k2s.exe"
$exclusionList += "$kubePath\k2s\cmd\vfprules\vfprules.exe"
$exclusionList += "$kubePath\k2s\cmd\httpproxy\httpproxy.exe"
$exclusionList += "$kubePath\k2s\cmd\devgon\devgon.exe"
$exclusionList += "$kubePath\k2s\cmd\bridge\bridge.exe"

# if the zip package is to be used for offline installation then use existing base image and windows node artifacts file
# or create a new one for the one that does not exist.
# Otherwise include the base image and the Windows node artifacts file in the exclusion list

$controlPlaneBaseVhdxPath = Get-ControlPlaneVMBaseImagePath
$winNodeArtifactsZipFilePath = Get-WindowsNodeArtifactsZipFilePath
if ($ForOfflineInstallation) {
    # Provide windows parts
    if (Test-Path $winNodeArtifactsZipFilePath) {
        Write-Log "The already existing file '$winNodeArtifactsZipFilePath' will be used." -Console
    } else {
        try {
            Write-Log "The file '$winNodeArtifactsZipFilePath' does not exist. Creating it using proxy $Proxy ..." -Console
            DownloadAndZipWindowsNodeArtifacts($winNodeArtifactsZipFilePath)
        }
        catch {
            Write-Log "Creation of file '$winNodeArtifactsZipFilePath' failed. Performing clean-up...Error: $_" -Console
            Invoke-DownloadsCleanup -DeleteFilesForOfflineInstallation $true

            if ($EncodeStructuredOutput -eq $true) {
                $err = New-Error -Code 'build-package-failed' -Message $_
                Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                return
            }
        
            Write-Log $_ -Error
            exit 1
        }
    }

    # Provide linux parts
    if (Test-Path $controlPlaneBaseVhdxPath) {
        Write-Log "The already existing file '$controlPlaneBaseVhdxPath' will be used." -Console
    } else {
        try {
            Write-Log "The file '$controlPlaneBaseVhdxPath' does not exist. Creating it..." -Console
            BuildAndProvisionKubemasterBaseImage -WindowsNodeArtifactsZip:$winNodeArtifactsZipFilePath -OutputPath:$controlPlaneBaseVhdxPath
        }
        catch {
            Write-Log "Creation of file '$controlPlaneBaseVhdxPath' failed. Performing clean-up... Error: $_" -Console
            Clear-ProvisioningArtifacts

            if ($EncodeStructuredOutput -eq $true) {
                $err = New-Error -Code 'build-package-failed' -Message $_
                Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                return
            }
        
            Write-Log $_ -Error
            exit 1
        }
    }
} else {
    $controlPlaneRootfsPath = Get-ControlPlaneVMRootfsPath
    $exclusionList += $controlPlaneBaseVhdxPath
    $exclusionList += $controlPlaneRootfsPath
    $exclusionList += $winNodeArtifactsZipFilePath
}

$kubenodeBaseVhdxPath = "$(Split-Path -Path $controlPlaneBaseVhdxPath)\Kubenode-Base.vhdx"
$exclusionList += $kubenodeBaseVhdxPath

Write-Log 'Content of the exclusion list:' -Console
$exclusionList | ForEach-Object { " - $_ " } | Write-Log -Console

# create the zip package
Write-Log 'Start creation of zip package...' -Console
CreateZipArchive -ExclusionList $exclusionList -BaseDirectory $kubePath -TargetPath "$zipPackagePath"
Write-Log 'Finished creation of zip package' -Console

Write-Log "Zip package available as '$zipPackagePath'." -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}