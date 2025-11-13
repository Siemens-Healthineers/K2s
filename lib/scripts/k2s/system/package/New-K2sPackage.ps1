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
    [string] $Password,
    [parameter(Mandatory = $false, HelpMessage = 'Packaging profile: Dev (default) or Lite (reduced footprint)')]
    [ValidateSet('Dev','Lite')]
    [string] $Profile = 'Dev',
    [parameter(Mandatory = $false, HelpMessage = 'Comma-separated list of addons to include in the package (default: all available addons)')]
    [string] $AddonsList = ''
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
Write-Log "- Profile: $Profile"
Write-Log "- Addons List: $AddonsList"

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
        [AllowEmptyCollection()]
        [string[]] $InclusionList = @()
    )
    
    Write-Log "Creating ZIP archive: $TargetPath from base directory: $BaseDirectory" -Console
    
    # Normalize the base directory to its full path to avoid 8.3 vs long name issues
    $normalizedBaseDirectory = (Get-Item $BaseDirectory).FullName
    Write-Log "BaseDirectory normalized: $normalizedBaseDirectory" -Console
    
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
                        $shouldSkip = $true
                        break
                    }
                }
                # Check inclusion list - both exact match and subdirectory match
                if ($shouldSkip) {
                    $shouldInclude = $false
                    # Check if file/directory is explicitly included OR is within an included directory
                    foreach ($inclusion in $InclusionList) {
                        if ($file -eq $inclusion -or $file.StartsWith("$inclusion\")) {
                            $shouldInclude = $true
                            break
                        }
                    }
                    if ($shouldInclude) {
                        Write-Log "Re-including whitelisted file: $file" -Console
                        $shouldSkip = $false
                    }
                }
                if ($shouldSkip) {
                    Write-Log "Skipping excluded file: $file"
                    $skippedCount++
                    continue
                }

                $relativeFilePath = $file.Replace("$normalizedBaseDirectory\", '')
                
                # Debug: Check if the replacement worked properly
                if ($relativeFilePath -eq $file) {
                    # Replacement didn't work, try alternative method
                    Write-Log "WARNING: Standard replacement failed for file: $file" -Console
                    Write-Log "BaseDirectory: $normalizedBaseDirectory" -Console
                    
                    # Try using Resolve-Path or manual substring
                    try {
                        $filePathResolved = (Resolve-Path $file).Path
                        if ($filePathResolved.StartsWith($normalizedBaseDirectory)) {
                            $relativeFilePath = $filePathResolved.Substring($normalizedBaseDirectory.Length).TrimStart('\')
                            Write-Log "Alternative method worked. Relative path: $relativeFilePath" -Console
                        } else {
                            Write-Log "ERROR: File path doesn't start with base directory!" -Error
                            Write-Log "File: $filePathResolved" -Error
                            Write-Log "Base: $normalizedBaseDirectory" -Error
                            continue
                        }
                    } catch {
                        Write-Log "ERROR: Could not resolve paths for relative calculation: $_" -Error
                        continue
                    }
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
$exclusionList += "$kubePath\k2s\cmd\vfprules\vfprules.exe"
$exclusionList += "$kubePath\k2s\cmd\httpproxy\httpproxy.exe"
$exclusionList += "$kubePath\k2s\cmd\devgon\devgon.exe"
$exclusionList += "$kubePath\k2s\cmd\bridge\bridge.exe"
$exclusionList += "$kubePath\bin\debian-12-genericcloud-amd64.qcow2"  # Large guest cloud image not needed in package

# Inclusion list (whitelist) - initialized empty; may be populated per profile
$inclusionList = @()

# Parse addons list if provided
$selectedAddons = @()
if ($AddonsList -ne '') {
    $selectedAddons = $AddonsList.Split(',') | ForEach-Object { $_.Trim() }
    Write-Log "[Addons] Custom addon list specified: $($selectedAddons -join ', ')" -Console
}

# Dynamically discover all available addon implementations by scanning the addons directory
function Get-AvailableAddons {
    param(
        [string]$AddonsRootPath
    )
    
    $addonPaths = @{}
    
    if (-not (Test-Path $AddonsRootPath)) {
        Write-Log "[Addons] Warning: Addons directory not found at '$AddonsRootPath'" -Console
        return $addonPaths
    }
    
    # Get all addon directories (exclude 'common' and module files)
    $addonDirs = Get-ChildItem -Path $AddonsRootPath -Directory | Where-Object { $_.Name -ne 'common' }
    
    foreach ($addonDir in $addonDirs) {
        $manifestPath = Join-Path $addonDir.FullName 'addon.manifest.yaml'
        
        if (Test-Path $manifestPath) {
            # Check if this addon has multiple implementations (subdirectories with Enable.ps1)
            $implDirs = Get-ChildItem -Path $addonDir.FullName -Directory | Where-Object {
                Test-Path (Join-Path $_.FullName 'Enable.ps1')
            }
            
            if ($implDirs.Count -gt 0) {
                # Multi-implementation addon (e.g., ingress with nginx/traefik)
                foreach ($implDir in $implDirs) {
                    $addonKey = "$($addonDir.Name) $($implDir.Name)"
                    $relativePath = "addons/$($addonDir.Name)/$($implDir.Name)"
                    $addonPaths[$addonKey] = $relativePath
                }
            } else {
                # Single-implementation addon (Enable.ps1 directly in addon folder)
                $enableScript = Join-Path $addonDir.FullName 'Enable.ps1'
                if (Test-Path $enableScript) {
                    $addonKey = $addonDir.Name
                    $relativePath = "addons/$($addonDir.Name)"
                    $addonPaths[$addonKey] = $relativePath
                }
            }
        }
    }
    
    return $addonPaths
}

# Check if a test directory name matches a selected addon
function Test-AddonTestFolderMatch {
    param(
        [string]$TestDirName,
        [string]$AddonName
    )
    
    # Extract base addon name (remove implementation suffix for multi-impl addons)
    $addonBaseName = $AddonName
    $implName = $null
    
    if ($AddonName -match '^(.+)\s+(.+)$') {
        # Multi-implementation addon like "ingress nginx"
        $addonBaseName = $matches[1]
        $implName = $matches[2]
        
        # For multi-impl addons, match:
        # 1. Exact base name (e.g., "ingress" for common tests)
        # 2. Base name with implementation (e.g., "ingress-nginx" or "ingress-nginx_sec_test")
        if ($TestDirName -eq $addonBaseName) {
            return $true
        }
        
        # Check if test folder specifically matches this implementation
        # Pattern: basename-implname (with optional suffix like _sec_test)
        if ($TestDirName -like "$addonBaseName-$implName*") {
            return $true
        }
        
        return $false
    } else {
        # Single-implementation addon - match exact name or with suffix
        return ($TestDirName -eq $addonBaseName -or $TestDirName -like "$addonBaseName`_*")
    }
}

# Restore plink.exe and pscp.exe from WindowsNodeArtifacts.zip
function Restore-PuttyToolsFromArchive {
    param(
        [string]$WindowsNodeArtifactsZipPath,
        [string]$PlinkDestination,
        [string]$PscpDestination
    )
    
    Write-Log "Restoring plink.exe and pscp.exe to bin folder from WindowsNodeArtifacts.zip..." -Console
    Write-Log "  WindowsNodeArtifacts.zip path: $WindowsNodeArtifactsZipPath (exists: $(Test-Path $WindowsNodeArtifactsZipPath))" -Console
    
    if (-not (Test-Path $WindowsNodeArtifactsZipPath)) {
        Write-Log "ERROR: WindowsNodeArtifacts.zip not found, cannot restore plink/pscp!" -Error
        return $false
    }
    
    # Extract them from WindowsNodeArtifacts.zip
    $tempExtractPath = Join-Path $env:TEMP "putty-restore-$(Get-Random)"
    try {
        New-Item -Path $tempExtractPath -ItemType Directory -Force | Out-Null
        Write-Log "  Extracting WindowsNodeArtifacts.zip to temp location..." -Console
        Expand-Archive -Path $WindowsNodeArtifactsZipPath -DestinationPath $tempExtractPath -Force
        
        Write-Log "  Temp extract path: $tempExtractPath" -Console
        
        # The structure is puttytools (one word, all lowercase) at root
        $puttytoolsDir = Join-Path $tempExtractPath 'puttytools'
        Write-Log "  Looking for puttytools directory: $puttytoolsDir (exists: $(Test-Path $puttytoolsDir))" -Console
        
        if (Test-Path $puttytoolsDir) {
            $plinkSource = Join-Path $puttytoolsDir 'plink.exe'
            $pscpSource = Join-Path $puttytoolsDir 'pscp.exe'
            
            Write-Log "  plink.exe source: $plinkSource (exists: $(Test-Path $plinkSource))" -Console
            Write-Log "  pscp.exe source: $pscpSource (exists: $(Test-Path $pscpSource))" -Console
            
            $restoredCount = 0
            if (Test-Path $plinkSource) {
                Copy-Item -Path $plinkSource -Destination $PlinkDestination -Force
                Write-Log "  Restored plink.exe" -Console
                $restoredCount++
            } else {
                Write-Log "  WARNING: plink.exe not found at $plinkSource" -Console
            }
            
            if (Test-Path $pscpSource) {
                Copy-Item -Path $pscpSource -Destination $PscpDestination -Force
                Write-Log "  Restored pscp.exe" -Console
                $restoredCount++
            } else {
                Write-Log "  WARNING: pscp.exe not found at $pscpSource" -Console
            }
            
            return ($restoredCount -eq 2)
        } else {
            Write-Log "  ERROR: puttytools directory not found at expected path: $puttytoolsDir" -Error
            Write-Log "  Contents of temp extract path:" -Console
            Get-ChildItem -Path $tempExtractPath -Recurse -Force | Select-Object -First 20 | ForEach-Object { Write-Log "    $($_.FullName)" -Console }
            return $false
        }
    }
    catch {
        Write-Log "ERROR: Failed to restore putty tools: $_" -Error
        return $false
    }
    finally {
        if (Test-Path $tempExtractPath) {
            Remove-Item -Path $tempExtractPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# Download plink.exe and pscp.exe using putty-tools module
function Get-PuttyToolsViaDownload {
    param(
        [string]$PlinkDestination,
        [string]$PscpDestination,
        [string]$Proxy,
        [string]$PuttyToolsModulePath
    )
    
    Write-Log "Downloading plink.exe and pscp.exe for package..." -Console
    
    if (-not (Test-Path $PuttyToolsModulePath)) {
        Write-Log "Warning: Could not find putty-tools module at $PuttyToolsModulePath" -Console
        return $false
    }
    
    try {
        Import-Module $PuttyToolsModulePath -Force
        
        $downloadedCount = 0
        if (-not (Test-Path $PlinkDestination)) {
            Invoke-DownloadPlink -Destination $PlinkDestination -Proxy $Proxy
            Write-Log "  Downloaded plink.exe" -Console
            $downloadedCount++
        }
        if (-not (Test-Path $PscpDestination)) {
            Invoke-DownloadPscp -Destination $PscpDestination -Proxy $Proxy
            Write-Log "  Downloaded pscp.exe" -Console
            $downloadedCount++
        }
        
        return ($downloadedCount -gt 0)
    }
    catch {
        Write-Log "ERROR: Failed to download putty tools: $_" -Error
        return $false
    }
}

# Ensure plink.exe and pscp.exe are available in bin folder
function Ensure-PuttyToolsAvailable {
    param(
        [string]$PlinkPath,
        [string]$PscpPath,
        [bool]$IsOfflineInstallation,
        [string]$WindowsNodeArtifactsZipPath,
        [string]$Proxy
    )
    
    Write-Log "Checking plink.exe and pscp.exe availability..." -Console
    Write-Log "  plink.exe path: $PlinkPath (exists: $(Test-Path $PlinkPath))" -Console
    Write-Log "  pscp.exe path: $PscpPath (exists: $(Test-Path $PscpPath))" -Console
    
    # Check if both tools already exist
    if ((Test-Path $PlinkPath) -and (Test-Path $PscpPath)) {
        Write-Log "  plink.exe and pscp.exe already present in bin folder" -Console
        return $true
    }
    
    if ($IsOfflineInstallation) {
        # For offline packages: restore from WindowsNodeArtifacts.zip
        return Restore-PuttyToolsFromArchive -WindowsNodeArtifactsZipPath $WindowsNodeArtifactsZipPath `
            -PlinkDestination $PlinkPath -PscpDestination $PscpPath
    } else {
        # For non-offline packages: download if not present
        $puttytoolsModulePath = "$PSScriptRoot/../../../../modules/k2s/k2s.node.module/windowsnode/downloader/artifacts/putty-tools/putty-tools.module.psm1"
        return Get-PuttyToolsViaDownload -PlinkDestination $PlinkPath -PscpDestination $PscpPath `
            -Proxy $Proxy -PuttyToolsModulePath $puttytoolsModulePath
    }
}

# Copy files to temporary directory for signing, excluding items from exclusion list
function Copy-FilesForSigning {
    param(
        [string]$SourcePath,
        [string]$DestinationPath,
        [string[]]$ExclusionList,
        [bool]$IsOfflineInstallation
    )
    
    Write-Log "Creating temporary copy for signing to avoid file locking issues..." -Console
    Write-Log "Temporary signing directory: $DestinationPath" -Console
    
    New-Item -Path $DestinationPath -ItemType Directory -Force | Out-Null
    
    $filesToCopy = Get-ChildItem -Path $SourcePath -Force -Recurse
    $copiedCount = 0
    $skippedCount = 0
    
    foreach ($file in $filesToCopy) {
        $relativePath = $file.FullName.Replace("$SourcePath\", '')
        $targetPath = Join-Path $DestinationPath $relativePath
        
        # Skip files in exclusion list
        $shouldExclude = $false
        foreach ($exclusion in $ExclusionList) {
            if ($file.FullName.StartsWith($exclusion)) {
                $shouldExclude = $true
                $skippedCount++
                break
            }
        }
        
        if ($IsOfflineInstallation -and -not $shouldExclude) {
            # No additional exclusions - let Set-K2sFileSignature handle file type filtering
            Write-Log "Including file for potential signing: $($file.FullName)"
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
                $copiedCount++
            }
        }
    }
    
    Write-Log "Copied $copiedCount files/folders, skipped $skippedCount excluded items" -Console
    return $copiedCount
}

# Sign contents of offline installation ZIP artifacts
function Invoke-OfflineArtifactsSigning {
    param(
        [string]$TempSigningPath,
        [string]$WindowsNodeArtifactsZipFilePath,
        [string]$CertificatePath,
        [securestring]$SecurePassword
    )
    
    Write-Log 'Signing contents of offline installation ZIP files...' -Console
    
    # Sign Windows Node Artifacts ZIP contents
    $winArtifactsZipInTemp = Join-Path (Join-Path $TempSigningPath "bin") (Split-Path $WindowsNodeArtifactsZipFilePath -Leaf)
    if (-not (Test-Path $winArtifactsZipInTemp)) {
        Write-Log "Windows Node Artifacts ZIP not found in temp directory, skipping signing" -Console
        return
    }
    
    Write-Log "Signing contents of Windows Node Artifacts: $winArtifactsZipInTemp" -Console
    $winArtifactsExtractPath = Join-Path $TempSigningPath "win-artifacts-extract"
    
    try {
        # Extract the ZIP
        New-Item -Path $winArtifactsExtractPath -ItemType Directory -Force | Out-Null
        Expand-Archive -Path $winArtifactsZipInTemp -DestinationPath $winArtifactsExtractPath -Force
        
        # Sign contents
        Set-K2sFileSignature -SourcePath $winArtifactsExtractPath -CertificatePath $CertificatePath -Password $SecurePassword -ExclusionList @()
        
        # Remove old ZIP and create new one with signed contents
        Remove-Item -Path $winArtifactsZipInTemp -Force
        Compress-Archive -Path "$winArtifactsExtractPath\*" -DestinationPath $winArtifactsZipInTemp -CompressionLevel Optimal
        
        Write-Log "Windows Node Artifacts contents signed and repackaged." -Console
    } 
    finally {
        if (Test-Path $winArtifactsExtractPath) {
            Remove-Item -Path $winArtifactsExtractPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    
    Write-Log 'Offline installation ZIP contents signing completed.' -Console
}

# Create signed package with all code signing steps
function New-SignedPackage {
    param(
        [string]$KubePath,
        [string[]]$ExclusionList,
        [string]$CertificatePath,
        [string]$Password,
        [string]$ZipPackagePath,
        [bool]$ForOfflineInstallation,
        [string]$WindowsNodeArtifactsZipFilePath,
        [bool]$EncodeStructuredOutput,
        [string]$MessageType,
        [string[]]$SelectedAddons,
        [hashtable]$AllAddonPaths
    )
    
    Write-Log 'Code signing requested - signing executables and scripts...' -Console
    
    # Validate that Password is provided
    if ([string]::IsNullOrEmpty($Password)) {
        $errMsg = "Password is required when providing a certificate path."
        Write-Log $errMsg -Error
        
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'code-signing-failed' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return $false
        }
        exit 1
    }
    
    # Convert string password to SecureString for internal use
    $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    
    # Create temporary directory for signing to avoid file locking issues
    $tempSigningPath = Join-Path $env:TEMP "k2s-package-signing-$(Get-Random)"
    
    try {
        # Copy files to temp directory
        $copiedCount = Copy-FilesForSigning -SourcePath $KubePath -DestinationPath $tempSigningPath `
            -ExclusionList $ExclusionList -IsOfflineInstallation $ForOfflineInstallation
        
        if ($copiedCount -eq 0) {
            Write-Log "WARNING: No files were copied for signing!" -Error
            return $false
        }
        
        # Filter addon manifests before signing (if applicable)
        Update-AddonManifestsInPackage -PackageRootPath $tempSigningPath -SelectedAddons $SelectedAddons -AllAddonPaths $AllAddonPaths
        
        # Sign files in temporary directory
        Write-Log "Signing all executables and PowerShell scripts with certificate: $CertificatePath" -Console
        Set-K2sFileSignature -SourcePath $tempSigningPath -CertificatePath $CertificatePath -Password $securePassword -ExclusionList @()
        Write-Log 'Code signing completed successfully.' -Console
        
        # For offline installation, sign contents of ZIP files
        if ($ForOfflineInstallation) {
            Invoke-OfflineArtifactsSigning -TempSigningPath $tempSigningPath `
                -WindowsNodeArtifactsZipFilePath $WindowsNodeArtifactsZipFilePath `
                -CertificatePath $CertificatePath -SecurePassword $securePassword
        }
        
        # Create ZIP package from signed files
        Write-Log 'Start creation of zip package from signed files...' -Console
        Write-Log "About to create ZIP with the following parameters:" -Console
        Write-Log "- Source directory: $tempSigningPath" -Console  
        Write-Log "- Target ZIP: $ZipPackagePath" -Console
        
        # Check if temp directory has content
        $tempFiles = Get-ChildItem -Path $tempSigningPath -Recurse -Force
        Write-Log "Temp directory contains $($tempFiles.Count) items" -Console
        if ($tempFiles.Count -eq 0) {
            Write-Log "WARNING: Temp signing directory is empty!" -Error
            return $false
        }
        
        # Use signed files from temporary directory for ZIP creation
        New-ZipArchive -ExclusionList @() -BaseDirectory $tempSigningPath -TargetPath $ZipPackagePath
        
        return $true
    } 
    catch {
        Write-Log "Error during code signing: $_" -Error
        if ($EncodeStructuredOutput -eq $true) {
            Send-ToCli -MessageType $MessageType -Message @{Error = "Code signing failed: $_" }
        }
        return $false
    } 
    finally {
        # Clean up temporary signing directory
        if (Test-Path $tempSigningPath) {
            Write-Log "Cleaning up temporary signing directory..." -Console
            Remove-Item -Path $tempSigningPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# Add exclusions for addon test folders that don't match selected addons
function Add-TestFolderExclusions {
    param(
        [string]$KubePath,
        [string[]]$SelectedAddons,
        [ref]$ExclusionListRef,
        [hashtable]$AllAddonPaths
    )
    
    $testAddonsPath = Join-Path $KubePath 'k2s/test/e2e/addons'
    if (-not (Test-Path $testAddonsPath)) {
        return
    }
    
    # Build a map of selected implementations per base addon
    $selectedImplsByAddon = @{}
    foreach ($addon in $SelectedAddons) {
        if ($addon -match '^(.+)\s+(.+)$') {
            # Multi-implementation addon like "ingress nginx"
            $baseName = $matches[1]
            $implName = $matches[2]
            
            if (-not $selectedImplsByAddon.ContainsKey($baseName)) {
                $selectedImplsByAddon[$baseName] = @()
            }
            $selectedImplsByAddon[$baseName] += $implName
        }
    }
    
    # Build a list of all known implementation names from AllAddonPaths
    $allKnownImpls = @{}
    foreach ($addonKey in $AllAddonPaths.Keys) {
        if ($addonKey -match '^(.+)\s+(.+)$') {
            $baseName = $matches[1]
            $implName = $matches[2]
            
            if (-not $allKnownImpls.ContainsKey($baseName)) {
                $allKnownImpls[$baseName] = @()
            }
            if ($allKnownImpls[$baseName] -notcontains $implName) {
                $allKnownImpls[$baseName] += $implName
            }
        }
    }
    
    $testAddonDirs = Get-ChildItem -Path $testAddonsPath -Directory
    foreach ($testDir in $testAddonDirs) {
        $testDirName = $testDir.Name
        $shouldInclude = $false
        
        # Check if this test directory matches any selected addon
        foreach ($addon in $SelectedAddons) {
            if (Test-AddonTestFolderMatch -TestDirName $testDirName -AddonName $addon) {
                $shouldInclude = $true
                break
            }
        }
        
        if ($shouldInclude) {
            Write-Log "[Addons] Including test folder for addon: k2s/test/e2e/addons/$testDirName" -Console
            
            # For multi-implementation addons, check if we need to exclude specific subdirectories
            if ($selectedImplsByAddon.ContainsKey($testDirName)) {
                $selectedImpls = $selectedImplsByAddon[$testDirName]
                $knownImpls = $allKnownImpls[$testDirName]
                
                # Check for implementation-specific subdirectories
                $implSubdirs = Get-ChildItem -Path $testDir.FullName -Directory -ErrorAction SilentlyContinue
                foreach ($implSubdir in $implSubdirs) {
                    $implSubdirName = $implSubdir.Name
                    
                    # Check if this subdirectory name matches a known implementation
                    if ($knownImpls -contains $implSubdirName) {
                        # This is an implementation-specific subdirectory
                        if ($selectedImpls -notcontains $implSubdirName) {
                            # Exclude this unselected implementation subdirectory
                            $subdirFullPath = Join-Path $KubePath "k2s/test/e2e/addons/$testDirName/$implSubdirName"
                            if (-not ($ExclusionListRef.Value -contains $subdirFullPath)) {
                                $ExclusionListRef.Value += $subdirFullPath
                            }
                            Write-Log "[Addons] Excluding test subdirectory: k2s/test/e2e/addons/$testDirName/$implSubdirName" -Console
                        } else {
                            Write-Log "[Addons] Including test subdirectory: k2s/test/e2e/addons/$testDirName/$implSubdirName" -Console
                        }
                    }
                }
            }
        } else {
            # Exclude this test folder since it doesn't match any selected addon
            $testDirFullPath = Join-Path $KubePath "k2s/test/e2e/addons/$testDirName"
            if (-not ($ExclusionListRef.Value -contains $testDirFullPath)) {
                $ExclusionListRef.Value += $testDirFullPath
            }
            Write-Log "[Addons] Excluding test folder: k2s/test/e2e/addons/$testDirName" -Console
        }
    }
}

# Filter addon manifest to only include selected implementations
function Update-AddonManifestForSelectedImplementations {
    param(
        [string]$ManifestPath,
        [string[]]$SelectedImplementations
    )
    
    if (-not (Test-Path $ManifestPath)) {
        Write-Log "Manifest not found: $ManifestPath" -Console
        return
    }
    
    Write-Log "Filtering manifest $ManifestPath to only include implementations: $($SelectedImplementations -join ', ')" -Console
    
    # Read the manifest file line by line
    $lines = Get-Content -Path $ManifestPath
    $filteredLines = @()
    $inImplementationsSection = $false
    $currentImplName = ''
    $skipCurrentImpl = $false
    $implementationLineIndent = 0
    
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        
        # Detect when we enter the implementations section
        if ($line -match '^\s*implementations:\s*$') {
            $inImplementationsSection = $true
            $filteredLines += $line
            continue
        }
        
        # If we're in implementations section, check for implementation entries
        if ($inImplementationsSection) {
            # Check if this is a new implementation entry (- name: xxx at the correct indent level)
            if ($line -match '^\s+- name:\s+(.+)$') {
                # Calculate indent level of this "- name:" line
                $currentIndent = ($line -replace '\S.*$', '').Length
                
                # If this is the first implementation, record the indent
                if ($implementationLineIndent -eq 0) {
                    $implementationLineIndent = $currentIndent
                }
                
                # Only treat as new implementation if at the same indent as first one
                if ($currentIndent -eq $implementationLineIndent) {
                    $currentImplName = $matches[1].Trim()
                    $skipCurrentImpl = $SelectedImplementations -notcontains $currentImplName
                    
                    if ($skipCurrentImpl) {
                        Write-Log "  Excluding implementation: $currentImplName" -Console
                        continue
                    } else {
                        Write-Log "  Including implementation: $currentImplName" -Console
                        $filteredLines += $line
                        continue
                    }
                }
            }
            
            # Check if we're exiting the implementations section (back to top-level key)
            if ($line -match '^\S' -and $line.Trim() -ne '') {
                $inImplementationsSection = $false
                $skipCurrentImpl = $false
                $implementationLineIndent = 0
                $filteredLines += $line
                continue
            }
            
            # We're inside implementations section - skip lines if current impl is not selected
            if ($skipCurrentImpl) {
                continue
            }
        }
        
        # Add all other lines
        $filteredLines += $line
    }
    
    # Validate that we have at least one implementation left
    $hasImplementations = $false
    $inImpls = $false
    foreach ($line in $filteredLines) {
        if ($line -match '^\s*implementations:\s*$') {
            $inImpls = $true
            continue
        }
        if ($inImpls -and $line -match '^\s+- name:\s+') {
            $hasImplementations = $true
            break
        }
        if ($inImpls -and $line -match '^\S') {
            break
        }
    }
    
    if (-not $hasImplementations) {
        Write-Log "  WARNING: No implementations left after filtering! Keeping original manifest." -Console
        return
    }
    
    # Write the filtered content back to the file
    $filteredLines | Set-Content -Path $ManifestPath -Force
    Write-Log "  Manifest filtered successfully" -Console
}

# Process all addon manifests and filter out non-selected implementations
function Update-AddonManifestsInPackage {
    param(
        [string]$PackageRootPath,
        [string[]]$SelectedAddons,
        [hashtable]$AllAddonPaths
    )
    
    if ($SelectedAddons.Count -eq 0) {
        Write-Log "No addon filtering needed - all addons included" -Console
        return
    }
    
    Write-Log "Processing addon manifests to filter implementations..." -Console
    
    $addonsPath = Join-Path $PackageRootPath 'addons'
    if (-not (Test-Path $addonsPath)) {
        Write-Log "Addons directory not found in package: $addonsPath" -Console
        return
    }
    
    # Group selected addons by base name to find multi-implementation scenarios
    $addonGroups = @{}
    foreach ($addon in $SelectedAddons) {
        if ($addon -match '^(.+)\s+(.+)$') {
            # Multi-implementation addon like "ingress nginx"
            $baseName = $matches[1]
            $implName = $matches[2]
            
            if (-not $addonGroups.ContainsKey($baseName)) {
                $addonGroups[$baseName] = @()
            }
            $addonGroups[$baseName] += $implName
        }
    }
    
    # Process each multi-implementation addon
    foreach ($baseName in $addonGroups.Keys) {
        $manifestPath = Join-Path $addonsPath "$baseName\addon.manifest.yaml"
        if (Test-Path $manifestPath) {
            $selectedImpls = $addonGroups[$baseName]
            Update-AddonManifestForSelectedImplementations -ManifestPath $manifestPath -SelectedImplementations $selectedImpls
        }
    }
}

# Exclude addon manifests for multi-implementation addons where no implementations are selected
function Add-UnselectedAddonManifestExclusions {
    param(
        [string]$KubePath,
        [string]$AddonsRootPath,
        [string[]]$SelectedAddons,
        [ref]$ExclusionListRef
    )
    
    $addonDirs = Get-ChildItem -Path $AddonsRootPath -Directory | Where-Object { $_.Name -ne 'common' }
    foreach ($addonDir in $addonDirs) {
        # Check if this is a multi-implementation addon
        $implDirs = Get-ChildItem -Path $addonDir.FullName -Directory | Where-Object {
            Test-Path (Join-Path $_.FullName 'Enable.ps1')
        }
        
        if ($implDirs.Count -gt 0) {
            # Multi-implementation addon - check if any implementation is selected
            $anyImplSelected = $false
            foreach ($implDir in $implDirs) {
                $addonKey = "$($addonDir.Name) $($implDir.Name)"
                if ($SelectedAddons -contains $addonKey) {
                    $anyImplSelected = $true
                    break
                }
            }
            
            # If no implementations selected, exclude the manifest
            if (-not $anyImplSelected) {
                $manifestPath = Join-Path $addonDir.FullName 'addon.manifest.yaml'
                if (Test-Path $manifestPath) {
                    $fullPath = Join-Path $KubePath "addons/$($addonDir.Name)/addon.manifest.yaml"
                    if (-not ($ExclusionListRef.Value -contains $fullPath)) {
                        $ExclusionListRef.Value += $fullPath
                    }
                }
            }
        }
    }
}

# Discover all available addons
$addonsRootPath = Join-Path $kubePath 'addons'
$allAddonPaths = Get-AvailableAddons -AddonsRootPath $addonsRootPath
Write-Log "[Addons] Discovered $($allAddonPaths.Count) addon implementations" -Console


if ($Profile -eq 'Lite') {
    Write-Log '[Profile] Applying Lite profile exclusions for reduced package size' -Console
    $liteExclude = @(
        (Join-Path $kubePath 'docs'),
        (Join-Path $kubePath 'build'),
        (Join-Path $kubePath 'bin/Kubemaster-Base.rootfs.tar.gz')
    )
    
    # Handle addon selection for Lite profile
    if ($selectedAddons.Count -gt 0) {
        # Specific addons requested: exclude those NOT selected
        $pathsToInclude = @()
        foreach ($addon in $selectedAddons) {
            if ($allAddonPaths.ContainsKey($addon)) {
                $pathsToInclude += $allAddonPaths[$addon]
            } else {
                Write-Log "[Addons] Warning: Unknown addon '$addon' - will be ignored" -Console
            }
        }
        
        # Exclude all addon paths NOT in the include list
        foreach ($addonPath in $allAddonPaths.Values) {
            if ($pathsToInclude -notcontains $addonPath) {
                $liteExclude += (Join-Path $kubePath $addonPath)
            }
        }
        
        # Exclude manifests for multi-implementation addons where no implementations are selected
        Add-UnselectedAddonManifestExclusions -KubePath $kubePath -AddonsRootPath $addonsRootPath `
            -SelectedAddons $selectedAddons -ExclusionListRef ([ref]$liteExclude)
        
        # Exclude test folders for NON-selected addons
        Add-TestFolderExclusions -KubePath $kubePath -SelectedAddons $selectedAddons `
            -ExclusionListRef ([ref]$liteExclude) -AllAddonPaths $allAddonPaths
        
        # Include test folders for selected addons
        $testAddonsPath = Join-Path $kubePath 'k2s/test/e2e/addons'
        if (Test-Path $testAddonsPath) {
            $testAddonDirs = Get-ChildItem -Path $testAddonsPath -Directory
            foreach ($testDir in $testAddonDirs) {
                $testDirName = $testDir.Name
                $shouldInclude = $false
                
                # Check if this test directory matches any selected addon
                foreach ($addon in $selectedAddons) {
                    # Extract base addon name (remove implementation suffix for multi-impl addons)
                    $addonBaseName = $addon
                    if ($addon -match '^(.+)\s+(.+)$') {
                        # Multi-implementation addon like "ingress nginx"
                        $addonBaseName = $matches[1]
                        $implName = $matches[2]
                        
                        # Check if test dir matches base name or full implementation name
                        # e.g., "ingress" or "ingress-nginx" for "ingress nginx"
                        if ($testDirName -eq $addonBaseName -or 
                            $testDirName -eq "$addonBaseName-$implName" -or
                            $testDirName -like "$addonBaseName*") {
                            $shouldInclude = $true
                            break
                        }
                    } else {
                        # Single-implementation addon
                        if ($testDirName -eq $addonBaseName -or $testDirName -like "$addonBaseName*") {
                            $shouldInclude = $true
                            break
                        }
                    }
                }
                
                if ($shouldInclude) {
                    $testDirFullPath = Join-Path $kubePath "k2s/test/e2e/addons/$testDirName"
                    $inclusionList += $testDirFullPath
                    Write-Log "[Addons] Including test folder for addon: k2s/test/e2e/addons/$testDirName" -Console
                }
            }
        }
        
        Write-Log "[Profile+Addons] Lite profile with selected addons: $($selectedAddons -join ', ')" -Console
    } else {
        # No addons list specified: include ALL addons (default behavior)
        # But still exclude the test folders entirely
        $liteExclude += (Join-Path $kubePath 'k2s/test/e2e/addons')
        Write-Log "[Profile] Lite profile: including all addons (default)" -Console
    }
    
    foreach ($p in $liteExclude) {
        if (-not ($exclusionList -contains $p)) { $exclusionList += $p }
    }

    # Also ensure root-level compiled k2s.exe (if present) is kept
    $rootK2sExe = Join-Path $kubePath 'k2s.exe'
    if (Test-Path $rootK2sExe) { $inclusionList += $rootK2sExe }
    $rootK2sExeLicense = Join-Path $kubePath 'k2s.exe.license'
    if (Test-Path $rootK2sExeLicense) { $inclusionList += $rootK2sExeLicense }
} elseif ($selectedAddons.Count -gt 0) {
    # Dev profile with custom addon list: exclude addons NOT in the selected list
    Write-Log "[Addons] Dev profile with custom addon list: $($selectedAddons -join ', ')" -Console
    
    $pathsToInclude = @()
    foreach ($addon in $selectedAddons) {
        if ($allAddonPaths.ContainsKey($addon)) {
            $pathsToInclude += $allAddonPaths[$addon]
        } else {
            Write-Log "[Addons] Warning: Unknown addon '$addon' - will be ignored" -Console
        }
    }
    
    # Exclude all addon paths NOT in the include list
    foreach ($addonPath in $allAddonPaths.Values) {
        if ($pathsToInclude -notcontains $addonPath) {
            $fullPath = Join-Path $kubePath $addonPath
            if (-not ($exclusionList -contains $fullPath)) { 
                $exclusionList += $fullPath 
            }
        }
    }
    
    # Exclude manifests for multi-implementation addons where no implementations are selected
    Add-UnselectedAddonManifestExclusions -KubePath $kubePath -AddonsRootPath $addonsRootPath `
        -SelectedAddons $selectedAddons -ExclusionListRef ([ref]$exclusionList)
    
    # Exclude test folders for NON-selected addons
    Add-TestFolderExclusions -KubePath $kubePath -SelectedAddons $selectedAddons `
        -ExclusionListRef ([ref]$exclusionList) -AllAddonPaths $allAddonPaths
} else {
    # Dev profile with no addon list: include ALL addons (default behavior)
    Write-Log "[Addons] Dev profile: including all addons (default)" -Console
}

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

# Ensure plink.exe and pscp.exe are available in bin folder for the package
$kubeBinPath = Get-KubeBinPath
$plinkPath = Join-Path $kubeBinPath 'plink.exe'
$pscpPath = Join-Path $kubeBinPath 'pscp.exe'

$puttytoolsResult = Ensure-PuttyToolsAvailable -PlinkPath $plinkPath -PscpPath $pscpPath `
    -IsOfflineInstallation $ForOfflineInstallation -WindowsNodeArtifactsZipPath $winNodeArtifactsZipFilePath `
    -Proxy $Proxy

if (-not $puttytoolsResult) {
    Write-Log "Warning: Could not ensure plink.exe and pscp.exe availability. Package may be incomplete." -Console
}

Write-Log 'Content of the exclusion list:' -Console
$exclusionList | ForEach-Object { " - $_ " } | Write-Log -Console

# Code signing logic (if requested)
if ($CertificatePath) {
    $signingResult = New-SignedPackage -KubePath $kubePath -ExclusionList $exclusionList `
        -CertificatePath $CertificatePath -Password $Password -ZipPackagePath $zipPackagePath `
        -ForOfflineInstallation $ForOfflineInstallation -WindowsNodeArtifactsZipFilePath $winNodeArtifactsZipFilePath `
        -EncodeStructuredOutput $EncodeStructuredOutput -MessageType $MessageType `
        -SelectedAddons $selectedAddons -AllAddonPaths $allAddonPaths
    
    if (-not $signingResult) {
        Write-Log "Code signing failed or was incomplete" -Error
        exit 1
    }
} else {
    Write-Log 'No code signing requested - creating standard package.' -Console
    
    # Filter addon manifests if custom addon selection
    if ($selectedAddons.Count -gt 0) {
        Write-Log 'Custom addon selection detected - creating temporary copy for manifest filtering...' -Console
        $tempPackagePath = Join-Path $env:TEMP "k2s-package-temp-$(Get-Random)"
        
        try {
            # Copy files to temp directory for manifest filtering
            $copiedCount = Copy-FilesForSigning -SourcePath $kubePath -DestinationPath $tempPackagePath `
                -ExclusionList $exclusionList -IsOfflineInstallation $ForOfflineInstallation
            
            if ($copiedCount -eq 0) {
                Write-Log "WARNING: No files were copied!" -Error
                exit 1
            }
            
            # Filter addon manifests in temp directory
            Update-AddonManifestsInPackage -PackageRootPath $tempPackagePath -SelectedAddons $selectedAddons -AllAddonPaths $allAddonPaths
            
            Write-Log 'Start creation of zip package from filtered files...' -Console
            New-ZipArchive -ExclusionList @() -BaseDirectory $tempPackagePath -TargetPath "$zipPackagePath"
        }
        finally {
            # Clean up temporary directory
            if (Test-Path $tempPackagePath) {
                Write-Log "Cleaning up temporary package directory..." -Console
                Remove-Item -Path $tempPackagePath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } else {
        # No filtering needed - create package directly from source
        Write-Log 'Start creation of zip package...' -Console
        New-ZipArchive -ExclusionList $exclusionList -BaseDirectory $kubePath -TargetPath "$zipPackagePath" -InclusionList $inclusionList
    }
}

Write-Log "Zip package available at '$zipPackagePath'." -Console

Write-Log 'Removing implicitly created K2s config dir'
Remove-Item -Path "$(Get-K2sConfigDir)" -Force -Recurse -ErrorAction SilentlyContinue

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}