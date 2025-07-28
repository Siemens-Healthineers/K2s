#Requires -Modules Pester

BeforeAll {
    # Define paths to the modules
    $infraModule = "$PSScriptRoot/../../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
    $nodeModule = "$PSScriptRoot/../../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"
    $clusterModule = "$PSScriptRoot/../../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
    $signingModule = "$PSScriptRoot/../../../../modules/k2s/k2s.signing.module/k2s.signing.module.psm1"

    # Track error messages and validation failures using script-level variables
    $script:errorMessages = @()
    $script:lastErrorMessage = ""
    $script:sentMessages = @()
    $script:errorCaptured = $false

    # Use script-level variables for tracking function calls
    $script:SetK2sFileSignatureCalled = $false
    $script:SetK2sFileSignatureParams = $null
    $script:NewZipArchiveCalled = $false
    $script:NewZipArchiveParams = $null

    # Import the modules
    Import-Module $infraModule, $nodeModule, $clusterModule, $signingModule -Force

    # Mock key functions to prevent actual execution
    Mock Initialize-Logging { } -ModuleName k2s.infra.module

    # Mock exit to capture script terminations
    function global:exit() {
        param($Code = 0)
        Write-Host "Exit was called with code $Code"
        # Set our flag if we encounter the password validation error case
        if ($Code -eq 1) {
            $script:exitCode = $Code
        }
    }
   
    # Mock infrastructure functions
    Mock Get-SystemDriveLetter { return "C" } -ModuleName k2s.infra.module
    Mock Get-SetupInfo { return @{ Error = "No installation found" } }
    Mock Get-KubePath { return "C:\TestKubePath" }
    Mock Get-ControlPlaneVMBaseImagePath { return "C:\TestPath\ControlPlane.vhdx" }
    Mock Get-ControlPlaneVMRootfsPath { return "C:\TestPath\rootfs.tar" }
    Mock Get-WindowsNodeArtifactsZipFilePath { return "C:\TestPath\WindowsNodeArtifacts.zip" }
    Mock Get-K2sConfigDir { return "C:\TestPath\K2sConfig" }

    # Mock file/directory operations globally
    Mock Test-Path {
        param($Path)
        switch ($Path) {
            "C:\TestTarget" { return $true }  # Target directory exists
            "C:\TestTarget\test-package.zip" { return $false }  # Zip package doesn't exist
            "C:\TestPath\K2sConfig" { return $false }  # Config dir doesn't exist
            "C:\TestCert\cert.pfx" { return $true }  # Certificate exists
            "C:\TestKubePath" { return $true }  # KubePath exists
            default { return $false }
        }
    }

    # Mock path utilities
    Mock Join-Path {
        param($Path, $ChildPath)
        return "$Path\$ChildPath"
    }

    # Mock Test-Path inside the signing module to return true for paths it needs
    Mock Test-Path { return $true } -ModuleName k2s.signing.module

    # Create dummy function to avoid errors when mocking
    function New-ZipArchive {}

    # Mock Add-Type (used in New-ZipArchive function)
    Mock Add-Type { } -ModuleName k2s.infra.module

    # Mock New-Error which is used for structured output
    Mock New-Error {
        param($Code, $Message)

        Write-Host "New-Error called with code '$Code' and message '$Message'"
        if ($Code -eq 'code-signing-failed' -and $Message -eq "Password is required when providing a certificate path.") {
            $script:errorCaptured = $true
            $script:lastErrorMessage = $Message
        }

        return @{
            Code = $Code
            Message = $Message
        }
    } -ModuleName k2s.infra.module
}

Describe "New-K2sPackage with Code Signing" {
    BeforeEach {
        # Reset tracking variables
        $script:errorCaptured = $false
        $script:lastErrorMessage = ""
        $script:errorMessages = @()
        $script:sentMessages = @()
        $script:SetK2sFileSignatureCalled = $false
        $script:NewZipArchiveCalled = $false

        # Mock Set-K2sFileSignature using the proper module-based approach
        Mock Set-K2sFileSignature {
            param(
                [string]$SourcePath,
                [string]$CertificatePath,
                [System.Security.SecureString]$Password,
                [string[]]$ExclusionList
            )

            # Record that the function was called for our test assertions
            $script:SetK2sFileSignatureCalled = $true
            $script:SetK2sFileSignatureParams = @{
                SourcePath = $SourcePath
                CertificatePath = $CertificatePath
                Password = $Password
                ExclusionList = $ExclusionList
            }
        } 

          # Mock Write-Log to capture error messages
        Mock Write-Log {
            param(
                [string[]] $Messages,
                [switch] $Console = $false,
                [switch] $Progress = $false,
                [switch] $IsError = $false,
                [switch] $Raw = $false,
                [switch] $Ssh = $false,
                [string] $Caller = ""
            )

            if ($Messages) {
                if ($IsError) {
                    Write-Host "Test captured error: $($Messages[0])"
                    $script:lastErrorMessage = $Messages[0]
                    $script:errorMessages += $Messages[0]
                    $script:errorCaptured = $true
                }
            }
        }
        # Mock Send-ToCli to capture structured output
        Mock Send-ToCli {
            param($MessageType, $Message)
            $script:sentMessages += $Message
            if ($Message.Error) {
                Write-Host "Captured structured error: $($Message.Error.Code) - $($Message.Error.Message)"
                $script:lastErrorMessage = $Message.Error.Message
                $script:errorMessages += $Message.Error.Message

                # Specifically look for our certificate validation error
                if ($Message.Error.Code -eq 'build-package-failed') {
                    $script:errorCaptured = $true
                }
            }
        }

        # Mock New-ZipArchive for each test
        Mock New-ZipArchive {
            param($ExclusionList, $BaseDirectory, $TargetPath)
            $script:NewZipArchiveCalled = $true
            $script:NewZipArchiveParams = @{
                ExclusionList = $ExclusionList
                BaseDirectory = $BaseDirectory
                TargetPath = $TargetPath
            }
        }
    }

    # This test verifies that Set-K2sFileSignature is called with the correct parameters
    # when both certificate and password are provided
    It "should call Set-K2sFileSignature when certificate and password are provided" {
        # Arrange
        $targetDirectory = "C:\TestTarget"
        $zipFileName = "test-package.zip"
        $certificatePath = "C:\TestCert\cert.pfx"
        $securePassword = ConvertTo-SecureString "testpassword" -AsPlainText -Force

        # Create script parameters with both certificate AND password
        $scriptParams = @{
            TargetDirectory = $targetDirectory
            ZipPackageFileName = $zipFileName
            CertificatePath = $certificatePath
            Password = $securePassword
            ForOfflineInstallation = $false
        }

        # Act - Execute the script with proper parameters
        . "$PSScriptRoot\New-K2sPackage.ps1" @scriptParams

        # Assert - Verify Set-K2sFileSignature was called with correct parameters
        $script:SetK2sFileSignatureCalled | Should -Be $true -Because "Set-K2sFileSignature should be called when certificate and password are provided"
        $script:SetK2sFileSignatureParams | Should -Not -Be $null
        $script:SetK2sFileSignatureParams.SourcePath | Should -Be "C:\TestKubePath"
        $script:SetK2sFileSignatureParams.CertificatePath | Should -Be $certificatePath
        $script:SetK2sFileSignatureParams.Password | Should -Be $securePassword
    }

    It "should validate empty target directory" {
        # Reset tracking variables
        $script:errorCaptured = $false
        $script:lastErrorMessage = ""

        $scriptParams = @{
            TargetDirectory = ""  # Empty target directory
            ZipPackageFileName = "test.zip"
            ForOfflineInstallation = $false
            EncodeStructuredOutput = $true
            MessageType = "test"
        }

        # Act - Execute the script
        . "$PSScriptRoot\New-K2sPackage.ps1" @scriptParams

        # Assert
        $expectedError = "The passed target directory is empty"
        $script:lastErrorMessage | Should -Be $expectedError -Because "Script should detect empty target directory"
        $script:errorCaptured | Should -Be $true -Because "Script should report error for empty target directory"
    }

    It "should validate non-existent target directory" {
        # Reset tracking variables
        $script:errorCaptured = $false
        $script:lastErrorMessage = ""

        # Mock Test-Path to return false for this specific path
        Mock Test-Path { return $false } -ParameterFilter { $Path -eq "C:\NonExistentPath" }

        $scriptParams = @{
            TargetDirectory = "C:\NonExistentPath"  # Non-existent directory
            ZipPackageFileName = "test.zip"
            ForOfflineInstallation = $false
            EncodeStructuredOutput = $true
            MessageType = "test"
        }

        # Act - Execute the script
        . "$PSScriptRoot\New-K2sPackage.ps1" @scriptParams

        # Assert
        $expectedError = "The passed target directory 'C:\NonExistentPath' could not be found"
        $script:lastErrorMessage | Should -Be $expectedError -Because "Script should detect non-existent directory"
        $script:errorCaptured | Should -Be $true -Because "Script should report error for non-existent directory"
    }

    It "should validate empty zip file name" {
        # Reset tracking variables
        $script:errorCaptured = $false
        $script:lastErrorMessage = ""

        # Mock Test-Path to return true for this specific path
        Mock Test-Path { return $true } -ParameterFilter { $Path -eq "C:\TestTarget" }

        $scriptParams = @{
            TargetDirectory = "C:\TestTarget"
            ZipPackageFileName = ""  # Empty file name
            ForOfflineInstallation = $false
            EncodeStructuredOutput = $true
            MessageType = "test"
        }

        # Act - Execute the script
        . "$PSScriptRoot\New-K2sPackage.ps1" @scriptParams

        # Assert
        $expectedError = "The passed zip package name is empty"
        $script:lastErrorMessage | Should -Be $expectedError -Because "Script should detect empty zip file name"
        $script:errorCaptured | Should -Be $true -Because "Script should report error for empty zip file name"
    }
}

# Add proper cleanup
AfterAll {
    # Remove imported modules to clean up the test environment
    Get-Module k2s.* | Remove-Module -Force -ErrorAction SilentlyContinue

    # Clean up any script variables
    $script:errorMessages = $null
    $script:lastErrorMessage = $null
    $script:sentMessages = $null
    $script:errorCaptured = $null
    $script:SetK2sFileSignatureCalled = $null
    $script:SetK2sFileSignatureParams = $null
    $script:NewZipArchiveCalled = $null
    $script:NewZipArchiveParams = $null
}
