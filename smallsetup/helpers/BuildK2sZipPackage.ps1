# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
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
    [parameter(Mandatory = $true, HelpMessage = 'Target directory')]
    [string] $TargetDirectory,
    [parameter(Mandatory = $true, HelpMessage = 'The name of the zip package (it must have the extension .zip)')]
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

$ErrorActionPreference = 'Continue'
if ($Trace) {
    Set-PSDebug -Trace 1
}

&$PSScriptRoot\..\common\GlobalVariables.ps1
. $PSScriptRoot\..\common\GlobalFunctions.ps1

$infraModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$logModule = "$PSScriptRoot/../ps-modules/log/log.module.psm1"
$setupInfoModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.cluster.module\setupinfo\setupinfo.module.psm1"

Import-Module $infraModule, $logModule, $setupInfoModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log "- Proxy to be used: $Proxy"
Write-Log "- Target Directory: $TargetDirectory"
Write-Log "- Package file name: $ZipPackageFileName"

Add-type -AssemblyName System.IO.Compression

function BuildAndProvisionKubemasterBaseImage($outputPath) {
    $validationModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.infra.module\validation\validation.module.psm1"
    Import-Module $validationModule
    Write-Log 'Create and provision the base image' -Console
    &"$global:KubernetesPath\smallsetup\baseimage\BuildAndProvisionKubemasterBaseImage.ps1" -Proxy $Proxy -OutputPath $outputPath -VMMemoryStartupBytes $VMMemoryStartupBytes -VMProcessorCount $VMProcessorCount
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
    Write-Log "Provisioned base image available as $outputPath" -Console
}

function DownloadAndZipWindowsNodeArtifacts($outputPath) {
    Write-Log "Download and create zip file with Windows node artifacts for $outputPath with proxy $Proxy" -Console
    try {
        &"$global:KubernetesPath\smallsetup\common\InstallBuildOnlySetup.ps1" -MasterVMMemory $VMMemoryStartupBytes -MasterVMProcessorCount $VMProcessorCount -MasterDiskSize $VMDiskSize -ShowLogs:$ShowLogs -Proxy $Proxy
    }
    finally {
        &"$global:KubernetesPath\smallsetup\common\UninstallBuildOnlySetup.ps1" -ShowLogs:$ShowLogs
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
        $errMsg = "'$global:ProductName' is installed on your system. Please uninstall '$global:ProductName' first and try again."
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
$exclusionList = @('.git', '.vscode', '.gitignore') | ForEach-Object { Join-Path $global:KubernetesPath $_ }
$exclusionList += "$global:KubernetesPath\k2s\cmd\k2s\k2s.exe"
$exclusionList += "$global:KubernetesPath\k2s\cmd\vfprules\vfprules.exe"
$exclusionList += "$global:KubernetesPath\k2s\cmd\httpproxy\httpproxy.exe"
$exclusionList += "$global:KubernetesPath\k2s\cmd\devgon\devgon.exe"
$exclusionList += "$global:KubernetesPath\k2s\cmd\bridge\bridge.exe"

# if the zip package is to be used for offline installation then use existing base image and windows node artifacts file
# or create a new one for the one that does not exist.
# Otherwise include the base image and the Windows node artifacts file in the exclusion list
$kubemasterBaseVhdxPath = Get-KubemasterBaseImagePath
$winNodeArtifactsZipFilePath = $global:WindowsNodeArtifactsZipFilePath
if ($ForOfflineInstallation) {
    # Provide windows parts
    if (Test-Path $winNodeArtifactsZipFilePath) {
        Write-Log "The already existing file '$winNodeArtifactsZipFilePath' will be used." -Console
    }
    else {
        try {
            Write-Log "The file '$winNodeArtifactsZipFilePath' does not exist. Creating it using proxy $Proxy ..." -Console
            DownloadAndZipWindowsNodeArtifacts($winNodeArtifactsZipFilePath)
        }
        catch {
            Write-Log "Creation of file '$winNodeArtifactsZipFilePath' failed. Performing clean-up...Error: $_" -Console
            &"$global:KubernetesPath\smallsetup\windowsnode\downloader\DownloadsCleaner.ps1"

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
    if (Test-Path $kubemasterBaseVhdxPath) {
        Write-Log "The already existing file '$kubemasterBaseVhdxPath' will be used." -Console
    }
    else {
        try {
            Write-Log "The file '$kubemasterBaseVhdxPath' does not exist. Creating it..." -Console
            BuildAndProvisionKubemasterBaseImage($kubemasterBaseVhdxPath)
        }
        catch {
            Write-Log "Creation of file '$kubemasterBaseVhdxPath' failed. Performing clean-up... Error: $_" -Console
            &"$global:KubernetesPath\smallsetup\baseimage\Cleaner.ps1"

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
    $kubemasterRootfsPath = Get-KubemasterRootfsPath
    $exclusionList += $kubemasterBaseVhdxPath
    $exclusionList += $kubemasterRootfsPath
    $exclusionList += $winNodeArtifactsZipFilePath
}

Write-Log 'Content of the exclusion list:' -Console
$exclusionList | ForEach-Object { " - $_ " } | Write-Log -Console

# create the zip package
Write-Log 'Start creation of zip package...' -Console
CreateZipArchive -ExclusionList $exclusionList -BaseDirectory $global:KubernetesPath -TargetPath "$zipPackagePath"
Write-Log 'Finished creation of zip package' -Console

Write-Log "Zip package available as '$zipPackagePath'." -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}