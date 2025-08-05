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
    [uint64]$VMDiskSize = 10GB,
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
    [string] $MessageType,
    [parameter(Mandatory = $false, HelpMessage = 'The path to local builds of Kubernetes binaries')]
    [string] $K8sBinsPath = '',
    [parameter(Mandatory = $false, HelpMessage = 'Path to code signing certificate (.pfx file)')]
    [string] $CertificatePath,
    [parameter(Mandatory = $false, HelpMessage = 'Password for the certificate file')]
    [string] $Password
)

$infraModule = "$PSScriptRoot/../../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot/../../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$signingModule = "$PSScriptRoot/../../../../modules/k2s/k2s.signing.module/k2s.signing.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule, $signingModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log "- Proxy to be used: $Proxy"
Write-Log "- Target Directory: $TargetDirectory"
Write-Log "- Package file name: $ZipPackageFileName"

Add-type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function New-ProvisionedKubemasterBaseImage($WindowsNodeArtifactsZip, $OutputPath) {
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
        Write-Log '  done'
        # Deploy putty tools
        Write-Log 'Temporarily deploying putty tools...' -Console
        Invoke-DeployPuttytoolsArtifacts $windowsNodeArtifactsDirectory
        # Provision linux node artifacts
        Write-Log 'Create and provision the base image' -Console
        $baseDirectory = $(Split-Path -Path $OutputPath)
        $rootfsPath = "$baseDirectory\$(Get-ControlPlaneOnWslRootfsFileName)"
        if (Test-Path -Path $rootfsPath) {
            Remove-Item -Path $rootfsPath -Force
            Write-Log "Deleted already existing file for WSL support '$rootfsPath'"
        }
        else {
            Write-Log "File for WSL support '$rootfsPath' does not exist. Nothing to delete."
        }
    
        $hostname = Get-ConfigControlPlaneNodeHostname
        $ipAddress = Get-ConfiguredIPControlPlane
        $gatewayIpAddress = Get-ConfiguredKubeSwitchIP
        $loopbackAdapter = Get-L2BridgeName
        $dnsServers = Get-DnsIpAddressesFromActivePhysicalNetworkInterfacesOnWindowsHost -ExcludeNetworkInterfaceName $loopbackAdapter
        if ([string]::IsNullOrWhiteSpace($dnsServers)) {
            $dnsServers = '8.8.8.8'
        }

        $controlPlaneNodeCreationParams = @{
            Hostname             = $hostname
            IpAddress            = $ipAddress
            GatewayIpAddress     = $gatewayIpAddress
            DnsServers           = $dnsServers
            VmImageOutputPath    = $OutputPath
            Proxy                = $Proxy
            VMMemoryStartupBytes = $VMMemoryStartupBytes
            VMProcessorCount     = $VMProcessorCount
            VMDiskSize           = $VMDiskSize
        }
        New-VmImageForControlPlaneNode @controlPlaneNodeCreationParams
    
        if (!(Test-Path -Path $OutputPath)) {
            throw "The file '$OutputPath' was not created"
        }
    

        $wslRootfsForControlPlaneNodeCreationParams = @{
            VmImageInputPath     = $OutputPath
            RootfsFileOutputPath = $rootfsPath
            Proxy                = $Proxy
            VMMemoryStartupBytes = $VMMemoryStartupBytes
            VMProcessorCount     = $VMProcessorCount
            VMDiskSize           = $VMDiskSize
        }
        New-WslRootfsForControlPlaneNode @wslRootfsForControlPlaneNodeCreationParams
    
        if (!(Test-Path -Path $rootfsPath)) {
            throw "The file '$rootfsPath' was not created"
        }
    }
    finally {
        Write-Log 'Deleting the putty tools...' -Console
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

function Get-AndZipWindowsNodeArtifacts($outputPath) {
    Write-Log "Download and create zip file with Windows node artifacts for $outputPath with proxy $Proxy" -Console
    $kubernetesVersion = Get-DefaultK8sVersion
    try {
        Invoke-DeployWinArtifacts -KubernetesVersion $kubernetesVersion -Proxy "$Proxy" -K8sBinsPath $K8sBinsPath
    }
    finally {
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

function New-ZipArchive() {
    Param(
        [parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $ExclusionList,
        [parameter(Mandatory = $true)]
        [string] $BaseDirectory,
        [parameter(Mandatory = $true)]
        [string] $TargetPath,
        [parameter(Mandatory = $false)]
        [bool] $PreserveK2sStructure = $false
    )
    
    Write-Log "Creating ZIP archive: $TargetPath from base directory: $BaseDirectory" -Console
    
    $files = Get-ChildItem -Path $BaseDirectory -Force -Recurse | ForEach-Object { $_.FullName }
    Write-Log "Found $($files.Count) total files and directories to process" -Console
    
    $fileStreamMode = [System.IO.FileMode]::Create
    $zipMode = [System.IO.Compression.ZipArchiveMode]::Create
    $compressionLevel = [System.IO.Compression.CompressionLevel]::Optimal

    $zipFileStream = $null
    $zipFile = $null
    
    try {
        $zipFileStream = [System.IO.File]::Open($TargetPath, $fileStreamMode)
        $zipFile = [System.IO.Compression.ZipArchive]::new($zipFileStream, $zipMode)
        Write-Log "ZIP archive opened successfully" -Console
        
        $addedCount = 0
        $skippedCount = 0
        
        foreach ($file in $files) {
            $sourceFileStream = $null
            $zipFileStreamEntry = $null
            
            try {
                # Check exclusion list
                $shouldSkip = $false
                foreach ($exclusion in $ExclusionList) {
                    if ($file.StartsWith($exclusion)) {
                        Write-Log "Skipping excluded file: $file"
                        $shouldSkip = $true
                        $skippedCount++
                        break
                    }
                }
                
                if ($shouldSkip) {
                    continue
                }

                $relativeFilePath = $file.Replace("$BaseDirectory\", '')
                
                # If preserving K2s structure (temp directory case), add k2s prefix
                if ($PreserveK2sStructure) {
                    $relativeFilePath = "k2s\$relativeFilePath"
                }
                
                $isDirectory = (Get-Item $file) -is [System.IO.DirectoryInfo]
                
                if ($isDirectory) {
                    Write-Log "Adding directory: $relativeFilePath"
                    $zipFileEntry = $zipFile.CreateEntry("$relativeFilePath\")
                    $addedCount++
                }
                else {
                    # Check if file exists and is accessible
                    if (-not (Test-Path $file -PathType Leaf)) {
                        Write-Log "Warning: File not found or not accessible: $file" -Console
                        continue
                    }
                    
                    Write-Log "Adding file: $relativeFilePath (Size: $((Get-Item $file).Length) bytes)"
                    $zipFileEntry = $zipFile.CreateEntry($relativeFilePath, $compressionLevel)
                    $zipFileStreamEntry = $zipFileEntry.Open()
                    $sourceFileStream = [System.IO.File]::OpenRead($file)
                    $sourceFileStream.CopyTo($zipFileStreamEntry)
                    $addedCount++
                }
            }
            catch {
                Write-Log "Error adding file '$file' to ZIP: $_" -Error
                # Don't break the entire process for one file error, but log it
                $skippedCount++
            }
            finally {
                # Properly dispose of streams for this file
                if ($sourceFileStream) { $sourceFileStream.Dispose() }
                if ($zipFileStreamEntry) { $zipFileStreamEntry.Dispose() }
            }
        }
        
        Write-Log "ZIP creation completed. Added: $addedCount, Skipped: $skippedCount" -Console
        
    }
    catch {
        Write-Log "CRITICAL ERROR in New-ZipArchive: $_" -Error
        
        # Clean up the partial ZIP file
        if ($zipFile) { $zipFile.Dispose() }
        if ($zipFileStream) { $zipFileStream.Dispose() }
        if (Test-Path $TargetPath) {
            Remove-Item $TargetPath -Force -ErrorAction SilentlyContinue
        }

        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'build-package-failed' -Message "ZIP creation failed: $_"
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
    
        Write-Log "ZIP creation failed: $_" -Error
        exit 1
    }
    finally {
        # Properly dispose of main ZIP resources
        if ($zipFile) { 
            $zipFile.Dispose() 
            Write-Log "ZIP file disposed successfully" -Console
        }
        if ($zipFileStream) { 
            $zipFileStream.Dispose() 
            Write-Log "ZIP file stream disposed successfully" -Console
        }
    }
    
    # Verify the created ZIP file
    if (Test-Path $TargetPath) {
        $zipSize = (Get-Item $TargetPath).Length
        Write-Log "ZIP file created successfully. Size: $zipSize bytes" -Console
        
        # Quick verification that the ZIP is readable
        try {
            $testZip = [System.IO.Compression.ZipFile]::OpenRead($TargetPath)
            $entryCount = $testZip.Entries.Count
            $testZip.Dispose()
            Write-Log "ZIP verification successful. Contains $entryCount entries" -Console
        }
        catch {
            Write-Log "Warning: ZIP file may be corrupted. Verification failed: $_" -Error
        }
    }
    else {
        Write-Log "ERROR: ZIP file was not created at expected path: $TargetPath" -Error
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
        if ($K8sBinsPath -ne '') {
            Compress-WindowsNodeArtifactsWithLocalKubeTools -K8sBinsPath $K8sBinsPath
        }
        Write-Log "The already existing file '$winNodeArtifactsZipFilePath' will be used." -Console
    }
    else {
        try {
            Write-Log "The file '$winNodeArtifactsZipFilePath' does not exist. Creating it using proxy $Proxy ..." -Console
            Get-AndZipWindowsNodeArtifacts($winNodeArtifactsZipFilePath)
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
    }
    else {
        try {
            Write-Log "The file '$controlPlaneBaseVhdxPath' does not exist. Creating it..." -Console
            New-ProvisionedKubemasterBaseImage -WindowsNodeArtifactsZip:$winNodeArtifactsZipFilePath -OutputPath:$controlPlaneBaseVhdxPath
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
}
else {
    $controlPlaneRootfsPath = Get-ControlPlaneVMRootfsPath
    $exclusionList += $controlPlaneBaseVhdxPath
    $exclusionList += $controlPlaneRootfsPath
    $exclusionList += $winNodeArtifactsZipFilePath
}

$kubenodeBaseVhdxPath = "$(Split-Path -Path $controlPlaneBaseVhdxPath)\Kubenode-Base.vhdx"
$exclusionList += $kubenodeBaseVhdxPath

Write-Log 'Content of the exclusion list:' -Console
$exclusionList | ForEach-Object { " - $_ " } | Write-Log -Console

# Code signing logic (if requested)
if ($CertificatePath) {
    Write-Log 'Code signing requested - signing executables and scripts...' -Console
    
    # Validate that Password is provided when using a certificate
    if ([string]::IsNullOrEmpty($Password)) {
        $errMsg = "Password is required when providing a certificate path."
        Write-Log $errMsg -Error
        
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'code-signing-failed' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        exit 1
    }
    
    # Convert string password to SecureString for internal use
    $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    
    # Create temporary directory for signing to avoid file locking issues
    $tempSigningPath = Join-Path $env:TEMP "k2s-package-signing-$(Get-Random)"
    
    try {
        Write-Log "Creating temporary copy for signing to avoid file locking issues..." -Console
        Write-Log "Temporary signing directory: $tempSigningPath" -Console
        
        # Create temporary directory and copy all files
        New-Item -Path $tempSigningPath -ItemType Directory -Force | Out-Null
        
        # Copy the entire kubePath structure to temp directory, excluding items in exclusion list
        # For offline installation, we need special handling of large files
        $filesToCopy = Get-ChildItem -Path $kubePath -Force -Recurse
        foreach ($file in $filesToCopy) {
            $relativePath = $file.FullName.Replace("$kubePath\", '')
            $targetPath = Join-Path $tempSigningPath $relativePath
            
            # Skip files in exclusion list
            $shouldExclude = $false
            foreach ($exclusion in $exclusionList) {
                if ($file.FullName.StartsWith($exclusion)) {
                    $shouldExclude = $true
                    break
                }
            }
        
            if ($ForOfflineInstallation -and -not $shouldExclude) {
                # No additional exclusions - let Set-K2sFileSignature handle file type filtering
                Write-Log "Including file for potential signing: $($file.FullName)" -Console
            }
            
            if (-not $shouldExclude) {
            if ($file.PSIsContainer) {
                New-Item -Path $targetPath -ItemType Directory -Force | Out-Null
            } else {
                $targetDir = Split-Path -Path $targetPath -Parent
                if (-not (Test-Path $targetDir)) {
                    New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
                }
                Copy-Item -Path $file.FullName -Destination $targetPath -Force
                }
            }
        }
        
        Write-Log "Signing all executables and PowerShell scripts with certificate: $CertificatePath" -Console
        # Sign files in temporary directory
        Set-K2sFileSignature -SourcePath $tempSigningPath -CertificatePath $CertificatePath -Password $securePassword -ExclusionList @()
        
        Write-Log 'Code signing completed successfully.' -Console
        
        # For offline installation, sign contents of ZIP files that were copied to temp directory
        if ($ForOfflineInstallation) {
            Write-Log 'Signing contents of offline installation ZIP files...' -Console
            
            # Sign Windows Node Artifacts ZIP contents
            $winArtifactsZipInTemp = Join-Path (Join-Path $tempSigningPath "bin") (Split-Path $winNodeArtifactsZipFilePath -Leaf)
            if (Test-Path $winArtifactsZipInTemp) {
                Write-Log "Signing contents of Windows Node Artifacts: $winArtifactsZipInTemp" -Console
                $winArtifactsExtractPath = Join-Path $tempSigningPath "win-artifacts-extract"
                
                try {
                    # Extract the ZIP
                    New-Item -Path $winArtifactsExtractPath -ItemType Directory -Force | Out-Null
                    Expand-Archive -Path $winArtifactsZipInTemp -DestinationPath $winArtifactsExtractPath -Force
                    
                    # Sign contents
                    Set-K2sFileSignature -SourcePath $winArtifactsExtractPath -CertificatePath $CertificatePath -Password $securePassword -ExclusionList @()
                    
                    # Remove old ZIP and create new one with signed contents
                    Remove-Item -Path $winArtifactsZipInTemp -Force
                    Compress-Archive -Path "$winArtifactsExtractPath\*" -DestinationPath $winArtifactsZipInTemp -CompressionLevel Optimal
                    
                    Write-Log "Windows Node Artifacts contents signed and repackaged." -Console
                } finally {
                    if (Test-Path $winArtifactsExtractPath) {
                        Remove-Item -Path $winArtifactsExtractPath -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            
            Write-Log 'Offline installation ZIP contents signing completed.' -Console
        }
        
        Write-Log 'Start creation of zip package from signed files...' -Console
        
        # Add debugging information
        Write-Log "About to create ZIP with the following parameters:" -Console
        Write-Log "- Source directory: $tempSigningPath" -Console  
        Write-Log "- Target ZIP: $zipPackagePath" -Console
        
        # Check if temp directory has content
        $tempFiles = Get-ChildItem -Path $tempSigningPath -Recurse -Force
        Write-Log "Temp directory contains $($tempFiles.Count) items" -Console
        if ($tempFiles.Count -eq 0) {
            Write-Log "WARNING: Temp signing directory is empty!" -Error
        }
        
        # Use signed files from temporary directory for ZIP creation
        New-ZipArchive -ExclusionList @() -BaseDirectory $tempSigningPath -TargetPath "$zipPackagePath"
        
    } catch {
        Write-Log "Error during code signing: $_" -Error
        if ($EncodeStructuredOutput -eq $true) {
            Send-ToCli -MessageType $MessageType -Message @{Error = "Code signing failed: $_" }
        }
        exit 1
    } finally {
        # Clean up temporary signing directory
        if (Test-Path $tempSigningPath) {
            Write-Log "Cleaning up temporary signing directory..." -Console
            Remove-Item -Path $tempSigningPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
} else {
    Write-Log 'No code signing requested - creating standard package.' -Console
    Write-Log 'Start creation of zip package...' -Console
    New-ZipArchive -ExclusionList $exclusionList -BaseDirectory $kubePath -TargetPath "$zipPackagePath"
}

Write-Log "Zip package available at '$zipPackagePath'." -Console

Write-Log 'Removing implicitly created K2s config dir'
Remove-Item -Path "$(Get-K2sConfigDir)" -Force -Recurse -ErrorAction SilentlyContinue

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}