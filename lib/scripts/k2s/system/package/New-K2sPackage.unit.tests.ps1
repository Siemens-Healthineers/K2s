# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

# Unit tests for New-K2sPackage.ps1
# These tests execute the actual script certificate logic with mocked external dependencies
# Focus on CertificatePath and CreateCertificate parameters as requested

BeforeAll {
    # Get the script path
    $script:PackageScriptPath = Join-Path $PSScriptRoot "New-K2sPackage.ps1"
    
    # Global mock call tracker
    $Global:MockCallTracker = @{
        NewK2sCodeSigningCertificate = @()
        InvokeK2sCodeSigning = @()
    }
    
    # Create mock functions in global scope - these need to override the real module functions
    function Global:New-K2sCodeSigningCertificate {
        param([string]$CertificateName)
        $Global:MockCallTracker.NewK2sCodeSigningCertificate += @{ CertificateName = $CertificateName }
        $certPath = Join-Path $TestDrive "created-cert.pfx"
        New-Item -Path $certPath -ItemType File -Force | Out-Null
        return @{
            FilePath = $certPath
            Password = (ConvertTo-SecureString "testpass" -AsPlainText -Force)
            Thumbprint = "ABC123DEF456"
        }
    }
    
    function Global:Invoke-K2sCodeSigning {
        param(
            [string]$SourcePath,
            [string]$CertificatePath,
            [System.Security.SecureString]$Password,
            [string[]]$ExclusionList
        )
        $Global:MockCallTracker.InvokeK2sCodeSigning += @{ 
            SourcePath = $SourcePath
            CertificatePath = $CertificatePath
            Password = $Password
            ExclusionList = $ExclusionList
        }
    }
    
    # Mock the Import-Module command to prevent real module loading
    function Global:Import-Module { 
        param($Name, $ModuleInfo, $Force, $Global, $PassThru, $AsCustomObject, $ArgumentList)
        # Do nothing - just prevent real module imports
    }
    
    # Mock additional functions that the real script calls
    function Global:Get-SetupInfo { 
        return @{ Name = $null; Version = $null; Error = "K2s is not installed" } 
    }
    function Global:Get-KubePath { 
        return $TestDrive 
    }
    function Global:Get-K2sConfigDir { 
        return Join-Path $TestDrive ".k2s" 
    }
    function Global:Get-WindowsNodeArtifactsZipFilePath { 
        return Join-Path $TestDrive "windowsnode-artifacts.zip" 
    }
    function Global:Get-ControlPlaneVMBaseImagePath { 
        return Join-Path $TestDrive "kubemaster-base.vhdx" 
    }
    function Global:Get-ControlPlaneVMRootfsPath { 
        return Join-Path $TestDrive "kubemaster-base.tar.gz" 
    }
    function Global:New-ZipArchive { 
        param($ExclusionList, $BaseDirectory, $TargetPath)
        # Create empty zip file for testing
        New-Item -Path $TargetPath -ItemType File -Force | Out-Null
    }
    function Global:Initialize-Logging { param($ShowLogs) }
    function Global:Write-Log { param($Message, [switch]$Console, [switch]$IsError) }
    function Global:Send-ToCli { param($MessageType, $Message) }
    function Global:New-Error { param($Code, $Message, $Severity) return @{ Code = $Code; Message = $Message } }
    function Global:Remove-Item { param($Path, [switch]$Force, [switch]$Recurse, $ErrorAction) }
    function Global:Test-Path { param($Path) return $true }
    function Global:Join-Path { param($Path, $ChildPath) return [System.IO.Path]::Combine($Path, $ChildPath) }
    function Global:Get-ChildItem { param($Path, [switch]$Force, [switch]$Recurse) return @() }
    
    # Test execution function that actually calls the real New-K2sPackage.ps1 script
    function Test-CertificateLogic {
        param(
            [string]$CertificatePath,
            [System.Security.SecureString]$Password,
            [switch]$CreateCertificate
        )
        
        # Reset the call tracker
        $Global:MockCallTracker.NewK2sCodeSigningCertificate = @()
        $Global:MockCallTracker.InvokeK2sCodeSigning = @()
        
        # Build parameters for the real script
        $scriptParams = @{
            TargetDirectory = $TestDrive
            ZipPackageFileName = "test-package.zip" 
            ShowLogs = $false
        }
        
        if ($CertificatePath) { $scriptParams.CertificatePath = $CertificatePath }
        if ($CreateCertificate) { $scriptParams.CreateCertificate = $true }
        if ($Password) { $scriptParams.Password = $Password }
        
        # Execute the actual New-K2sPackage.ps1 script
        try {
            & $script:PackageScriptPath @scriptParams
        }
        catch {
            # Capture any errors but continue - we're testing the certificate logic
            Write-Host "Script execution error (expected with mocking): $_"
        }
        
        return $Global:MockCallTracker
    }
}

# Focus on CertificatePath and CreateCertificate parameters
Describe "New-K2sPackage.ps1 Certificate Parameter Execution Tests" {

    Context "CreateCertificate Parameter Tests" {
        It "should create certificate when CreateCertificate switch is used" {
            # Act - Test certificate creation logic
            $result = Test-CertificateLogic -CreateCertificate
            
            # Assert - Verify certificate creation was called
            $result.NewK2sCodeSigningCertificate.Count | Should -Be 1
            $result.NewK2sCodeSigningCertificate[0].CertificateName | Should -Be "K2s Code Signing"
            $result.InvokeK2sCodeSigning.Count | Should -Be 1
        }

        It "should not create certificate when CreateCertificate switch is not used" {
            # Act - Test without certificate creation
            $result = Test-CertificateLogic
            
            # Assert - Verify certificate creation was NOT called
            $result.NewK2sCodeSigningCertificate.Count | Should -Be 0
            $result.InvokeK2sCodeSigning.Count | Should -Be 0
        }

        It "should pass certificate name when creating certificate" {
            # Act
            $result = Test-CertificateLogic -CreateCertificate
            
            # Assert - Verify certificate creation was called with correct name
            $result.NewK2sCodeSigningCertificate.Count | Should -Be 1
            $result.NewK2sCodeSigningCertificate[0].CertificateName | Should -Be "K2s Code Signing"
        }
    }

    Context "CertificatePath Parameter Tests" {
        It "should use existing certificate when CertificatePath is provided" {
            # Arrange
            $testCertPath = Join-Path $TestDrive "existing-cert.pfx"
            New-Item -Path $testCertPath -ItemType File -Force | Out-Null
            
            # Act - Test with existing certificate path
            $result = Test-CertificateLogic -CertificatePath $testCertPath
            
            # Assert - Should use existing certificate, not create new one
            $result.NewK2sCodeSigningCertificate.Count | Should -Be 0
            $result.InvokeK2sCodeSigning.Count | Should -Be 1
            $result.InvokeK2sCodeSigning[0].CertificatePath | Should -Be $testCertPath
        }

        It "should prioritize certificate creation over existing path when both parameters are provided" {
            # Arrange
            $testCertPath = Join-Path $TestDrive "existing-cert.pfx"
            New-Item -Path $testCertPath -ItemType File -Force | Out-Null
            
            # Act - Test with both CertificatePath and CreateCertificate
            $result = Test-CertificateLogic -CertificatePath $testCertPath -CreateCertificate
            
            # Assert - Should create new certificate (CreateCertificate takes precedence)
            $result.NewK2sCodeSigningCertificate.Count | Should -Be 1
            $result.InvokeK2sCodeSigning.Count | Should -Be 1
            # The CertificatePath will be overwritten by the newly created certificate
        }
    }

    Context "Certificate Parameter Integration Tests" {
        It "should handle Password parameter when provided with CertificatePath" {
            # Arrange
            $testCertPath = Join-Path $TestDrive "existing-cert.pfx"
            $testPassword = ConvertTo-SecureString "mypassword" -AsPlainText -Force
            New-Item -Path $testCertPath -ItemType File -Force | Out-Null
            
            # Act
            $result = Test-CertificateLogic -CertificatePath $testCertPath -Password $testPassword
            
            # Assert - Password should be passed to signing function
            $result.InvokeK2sCodeSigning.Count | Should -Be 1
            $result.InvokeK2sCodeSigning[0].Password | Should -Be $testPassword
            $result.InvokeK2sCodeSigning[0].CertificatePath | Should -Be $testCertPath
        }

        It "should create package without certificate parameters" {
            # Act - Test without any certificate parameters
            $result = Test-CertificateLogic
            
            # Assert - No certificate operations should occur
            $result.NewK2sCodeSigningCertificate.Count | Should -Be 0
            $result.InvokeK2sCodeSigning.Count | Should -Be 0
        }

        It "should handle certificate creation without password" {
            # Act - Test certificate creation without explicit password
            $result = Test-CertificateLogic -CreateCertificate
            
            # Assert - Should create certificate and sign
            $result.NewK2sCodeSigningCertificate.Count | Should -Be 1
            $result.InvokeK2sCodeSigning.Count | Should -Be 1
            # Note: Password is provided by the mock certificate creation, so it won't be null
        }

        It "should validate that CreateCertificate takes precedence over CertificatePath" {
            # Arrange
            $testCertPath = Join-Path $TestDrive "existing-cert.pfx"
            $testPassword = ConvertTo-SecureString "mypassword" -AsPlainText -Force
            New-Item -Path $testCertPath -ItemType File -Force | Out-Null
            
            # Act - Provide both certificate path and create certificate
            $result = Test-CertificateLogic -CertificatePath $testCertPath -CreateCertificate -Password $testPassword
            
            # Assert - Should create new certificate (CreateCertificate takes precedence)
            $result.NewK2sCodeSigningCertificate.Count | Should -Be 1 "Should create certificate when CreateCertificate is specified"
            $result.InvokeK2sCodeSigning.Count | Should -Be 1 "Should still perform signing"
            $result.NewK2sCodeSigningCertificate[0].CertificateName | Should -Be "K2s Code Signing" "Should use correct certificate name"
        }
    }
}
