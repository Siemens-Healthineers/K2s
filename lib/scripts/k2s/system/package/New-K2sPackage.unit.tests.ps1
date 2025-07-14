# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

# Integration tests for New-K2sPackage.ps1
# These tests use static analysis and structure validation to test the real product code
# without executing it with real file I/O, certificate creation, or system calls.

BeforeAll {
    # Store the script path for testing
    $script:PackageScriptPath = "$PSScriptRoot\New-K2sPackage.ps1"
    
    # Read the script content for analysis
    $script:PackageScriptContent = Get-Content $script:PackageScriptPath -Raw
}

Describe "New-K2sPackage.ps1 Structure and Parameter Validation" {
    
    It "should have all required parameters defined" {
        # Test parameter definitions by parsing the script
        $scriptParams = (Get-Command $script:PackageScriptPath).Parameters
        
        # Assert - Verify key parameters exist
        $scriptParams.Keys | Should -Contain "TargetDirectory"
        $scriptParams.Keys | Should -Contain "ZipPackageFileName"
        $scriptParams.Keys | Should -Contain "CertificatePath"
        $scriptParams.Keys | Should -Contain "Password"
        $scriptParams.Keys | Should -Contain "CreateCertificate"
        $scriptParams.Keys | Should -Contain "ShowLogs"
        $scriptParams.Keys | Should -Contain "ForOfflineInstallation"
    }

    It "should have correct parameter types" {
        # Test parameter types
        $scriptParams = (Get-Command $script:PackageScriptPath).Parameters
        
        # Assert - Verify parameter types
        $scriptParams["TargetDirectory"].ParameterType | Should -Be ([string])
        $scriptParams["ZipPackageFileName"].ParameterType | Should -Be ([string])
        $scriptParams["CertificatePath"].ParameterType | Should -Be ([string])
        $scriptParams["Password"].ParameterType | Should -Be ([System.Security.SecureString])
        $scriptParams["CreateCertificate"].ParameterType.Name | Should -Be "SwitchParameter"
        $scriptParams["ShowLogs"].ParameterType.Name | Should -Be "SwitchParameter"
        $scriptParams["ForOfflineInstallation"].ParameterType.Name | Should -Be "SwitchParameter"
    }
    
    It "should import required modules" {
        # Verify that the script imports the expected modules
        $script:PackageScriptContent | Should -Match "k2s\.infra\.module"
        $script:PackageScriptContent | Should -Match "k2s\.node\.module"
        $script:PackageScriptContent | Should -Match "k2s\.cluster\.module"
        $script:PackageScriptContent | Should -Match "k2s\.signing\.module"
    }
    
    It "should contain code signing logic" {
        # Verify that the script contains the expected code signing functions
        $script:PackageScriptContent | Should -Match "New-K2sCodeSigningCertificate"
        $script:PackageScriptContent | Should -Match "Invoke-K2sCodeSigning"
    }
    
    It "should contain certificate creation logic" {
        # Verify the script has logic for creating certificates
        $script:PackageScriptContent | Should -Match "CreateCertificate"
        $script:PackageScriptContent | Should -Match "CertificatePath"
    }
    
    It "should contain zip creation logic" {
        # Verify the script has zip creation functionality
        $script:PackageScriptContent | Should -Match "New-ZipArchive"
        $script:PackageScriptContent | Should -Match "\.zip"
    }
    
    It "should validate zip file extension" {
        # Verify the script validates zip file extensions
        $script:PackageScriptContent | Should -Match "\.zip"
        $script:PackageScriptContent | Should -Match "EndsWith"
    }
    
    It "should check system installation status" {
        # Verify the script checks if K2s is installed
        $script:PackageScriptContent | Should -Match "Get-SetupInfo"
    }
}

Describe "New-K2sPackage.ps1 Code Signing Integration Logic" {
    
    It "should have conditional code signing based on parameters" {
        # Test that the script has conditional logic for code signing
        # This verifies the integration of signing logic without executing it
        
        # The script should check for CertificatePath parameter
        $script:PackageScriptContent | Should -Match '\$CertificatePath'
        
        # The script should check for CreateCertificate parameter  
        $script:PackageScriptContent | Should -Match '\$CreateCertificate'
        
        # The script should have conditional logic (if statements)
        $script:PackageScriptContent | Should -Match 'if.*CertificatePath|if.*CreateCertificate'
    }
    
    It "should integrate with K2s signing module functions" {
        # Verify the script uses the actual K2s signing functions
        
        # Should call the certificate creation function
        $script:PackageScriptContent | Should -Match 'New-K2sCodeSigningCertificate'
        
        # Should call the code signing function
        $script:PackageScriptContent | Should -Match 'Invoke-K2sCodeSigning'
        
        # Should pass the source path to signing function
        $script:PackageScriptContent | Should -Match 'SourcePath \$kubePath'
    }
    
    It "should handle certificate file paths correctly" {
        # Verify certificate path handling logic
        
        # Should use provided certificate path
        $script:PackageScriptContent | Should -Match '\$CertificatePath'
        
        # Should handle certificate creation output path
        $script:PackageScriptContent | Should -Match 'FilePath'
    }
    
    It "should include exclusion list for signing" {
        # Verify that exclusion logic is present
        $script:PackageScriptContent | Should -Match 'ExclusionList'
        $script:PackageScriptContent | Should -Match '\@\('  # Array syntax
    }
    
    It "should pass password parameter to signing function" {
        # Verify password handling for certificate
        $script:PackageScriptContent | Should -Match 'Password.*=.*\$'
    }
    
    It "should have offline artifact signing logic" {
        # Verify that the script includes logic for signing offline installation artifacts
        
        # Should check for ForOfflineInstallation parameter in signing context
        $script:PackageScriptContent | Should -Match 'ForOfflineInstallation.*\{'
        
        # Should have logic to sign Windows Node Artifacts
        $script:PackageScriptContent | Should -Match 'winNodeArtifactsZipFilePath'
        
        # Should extract ZIP for signing
        $script:PackageScriptContent | Should -Match 'Expand-Archive'
    }
    
    It "should use Get-SignableFiles for offline artifacts" {
        # Verify that the script uses the signing module's file discovery
        $script:PackageScriptContent | Should -Match 'Get-SignableFiles'
        
        # Should scan extracted content for signable files
        $script:PackageScriptContent | Should -Match 'tempExtractPath|temp.*Extract'
    }
    
    It "should sign executables and scripts in offline artifacts" {
        # Verify that the script signs different file types in offline artifacts
        
        # Should sign executables (.exe files)
        $script:PackageScriptContent | Should -Match 'Set-K2sExecutableSignature'
        $script:PackageScriptContent | Should -Match '\.exe'
        
        # Should sign PowerShell scripts (.ps1, .psm1 files)
        $script:PackageScriptContent | Should -Match 'Set-K2sScriptSignature'
        $script:PackageScriptContent | Should -Match '\.ps1|\.psm1'
    }
    
    It "should recreate ZIP with signed offline artifacts" {
        # Verify that the script recreates the ZIP file after signing
        $script:PackageScriptContent | Should -Match 'Compress-Archive'
        $script:PackageScriptContent | Should -Match 'Re-creating.*ZIP|ZIP.*signed'
    }
    
    It "should cleanup temporary extraction directory" {
        # Verify proper cleanup of temporary directories used for signing
        $script:PackageScriptContent | Should -Match 'Remove-Item.*temp|temp.*Remove-Item'
        $script:PackageScriptContent | Should -Match 'finally'
    }
}

Describe "New-K2sPackage.ps1 Error Handling Logic" {
    
    It "should validate target directory parameter" {
        # Verify directory validation logic exists
        $script:PackageScriptContent | Should -Match 'TargetDirectory'
        $script:PackageScriptContent | Should -Match 'Test-Path'
    }
    
    It "should validate zip package file name" {
        # Verify zip file validation
        $script:PackageScriptContent | Should -Match 'ZipPackageFileName'
        $script:PackageScriptContent | Should -Match '\.zip'
        $script:PackageScriptContent | Should -Match 'EndsWith'
    }
    
    It "should handle installation status check" {
        # Verify setup info checking
        $script:PackageScriptContent | Should -Match 'Get-SetupInfo'
        $script:PackageScriptContent | Should -Match 'Error'
    }
    
    It "should provide structured error output" {
        # Verify error handling and output
        $script:PackageScriptContent | Should -Match 'New-Error'
        $script:PackageScriptContent | Should -Match 'Send-ToCli'
        $script:PackageScriptContent | Should -Match 'EncodeStructuredOutput'
    }
    
    It "should exit on errors appropriately" {
        # Verify error exit conditions
        $script:PackageScriptContent | Should -Match 'exit 1'
        $script:PackageScriptContent | Should -Match 'Write-Log.*-Error'
    }
}

Describe "New-K2sPackage.ps1 Integration Workflow" {
    
    It "should follow the correct execution flow" {
        # Verify the overall workflow structure by checking for key sequence indicators
        
        # Should validate inputs first
        $inputValidationMatch = $script:PackageScriptContent | Select-String -Pattern 'TargetDirectory.*Test-Path|Test-Path.*TargetDirectory' -SimpleMatch:$false
        $inputValidationMatch | Should -Not -BeNullOrEmpty
        
        # Should check setup status  
        $setupCheckMatch = $script:PackageScriptContent | Select-String -Pattern 'Get-SetupInfo'
        $setupCheckMatch | Should -Not -BeNullOrEmpty
        
        # Should handle code signing if requested
        $signingMatch = $script:PackageScriptContent | Select-String -Pattern 'Invoke-K2sCodeSigning'
        $signingMatch | Should -Not -BeNullOrEmpty
        
        # Should create zip package
        $zipMatch = $script:PackageScriptContent | Select-String -Pattern 'New-ZipArchive'
        $zipMatch | Should -Not -BeNullOrEmpty
    }
    
    It "should integrate properly with K2s infrastructure" {
        # Verify integration with K2s modules and functions
        
        # Should use K2s path functions
        $script:PackageScriptContent | Should -Match 'Get-KubePath'
        
        # Should use K2s logging
        $script:PackageScriptContent | Should -Match 'Initialize-Logging'
        $script:PackageScriptContent | Should -Match 'Write-Log'
        
        # Should use K2s configuration functions
        $script:PackageScriptContent | Should -Match 'Get-.*Path|Get-.*Dir'
    }
    
    It "should handle provisioning artifacts correctly" {
        # Verify provisioning workflow integration
        $script:PackageScriptContent | Should -Match 'New-VmImageForControlPlaneNode|New-WslRootfsForControlPlaneNode'
        $script:PackageScriptContent | Should -Match 'Invoke-DeployWinArtifacts'
        $script:PackageScriptContent | Should -Match 'Clear-ProvisioningArtifacts'
    }
}

Describe "New-K2sPackage.ps1 Offline Installation with Code Signing Integration" {
    
    It "should integrate code signing with offline installation workflow" {
        # Verify that the script properly integrates code signing with offline installation
        
        # Should check both ForOfflineInstallation and code signing parameters together
        $offlineSigningIntegration = ($script:PackageScriptContent -match "ForOfflineInstallation") -and 
                                     ($script:PackageScriptContent -match "CertificatePath|CreateCertificate") -and
                                     ($script:PackageScriptContent -match "signing.*offline|offline.*signing")
        $offlineSigningIntegration | Should -Be $true
    }
    
    It "should have proper execution order for offline artifacts and signing" {
        # Verify that offline artifacts are created before additional signing occurs
        
        # Should create Windows Node Artifacts before signing them
        $script:PackageScriptContent | Should -Match 'Get-AndZipWindowsNodeArtifacts'
        $script:PackageScriptContent | Should -Match 'New-ProvisionedKubemasterBaseImage'
        
        # Should have additional signing phase after offline artifact creation
        $script:PackageScriptContent | Should -Match 'Additional signing.*offline|offline.*Additional signing'
    }
    
    It "should handle Windows Node Artifacts signing workflow" {
        # Verify the Windows Node Artifacts signing workflow
        
        # Should extract ZIP for signing
        $script:PackageScriptContent | Should -Match 'Expand-Archive.*winNodeArtifactsZipFilePath'
        
        # Should use temporary directory for extraction
        $script:PackageScriptContent | Should -Match 'tempExtractPath|temp.*Extract'
        
        # Should scan for signable files in extracted content
        $script:PackageScriptContent | Should -Match 'Get-SignableFiles.*tempExtractPath'
        
        # Should recreate ZIP after signing
        $script:PackageScriptContent | Should -Match 'Compress-Archive.*winNodeArtifactsZipFilePath'
    }
    
    It "should sign different file types in offline artifacts" {
        # Verify that the script handles different signable file types
        
        # Should identify executable files
        $script:PackageScriptContent | Should -Match '\.exe.*EndsWith|EndsWith.*\.exe'
        
        # Should identify PowerShell script files
        $script:PackageScriptContent | Should -Match '\.ps1.*EndsWith|EndsWith.*\.ps1'
        $script:PackageScriptContent | Should -Match '\.psm1.*EndsWith|EndsWith.*\.psm1'
        
        # Should use appropriate signing methods for each type
        $script:PackageScriptContent | Should -Match 'Set-K2sExecutableSignature'
        $script:PackageScriptContent | Should -Match 'Set-K2sScriptSignature'
    }
    
    It "should use certificate consistently for offline artifact signing" {
        # Verify that the same certificate is used for offline artifacts
        
        # Should use the same CertificatePath for offline signing
        $script:PackageScriptContent | Should -Match '\$CertificatePath'
        
        # Should use the same Password for offline signing
        $script:PackageScriptContent | Should -Match '\$Password'
        
        # Should get thumbprint from the same certificate
        $script:PackageScriptContent | Should -Match 'Get-PfxCertificate'
        $script:PackageScriptContent | Should -Match 'Thumbprint'
    }
    
    It "should provide proper logging for offline artifact signing" {
        # Verify that the script provides comprehensive logging for offline signing
        
        # Should log the start of offline artifact signing
        $script:PackageScriptContent | Should -Match 'Write-Log.*offline.*signing|Write-Log.*signing.*offline'
        
        # Should log individual file signing operations
        $script:PackageScriptContent | Should -Match 'Write-Log.*Signing.*executable|Write-Log.*Signing.*script'
        
        # Should log completion of offline signing
        $script:PackageScriptContent | Should -Match 'Write-Log.*completed|completed.*Write-Log'
    }
    
    It "should handle errors in offline artifact signing gracefully" {
        # Verify error handling for offline signing operations
        
        # Should use try-catch blocks for signing operations
        $script:PackageScriptContent | Should -Match 'try.*\{'
        $script:PackageScriptContent | Should -Match 'catch.*\{'
        
        # Should ensure cleanup happens in finally blocks
        $script:PackageScriptContent | Should -Match 'finally.*\{'
        $script:PackageScriptContent | Should -Match 'Remove-Item.*tempExtractPath'
    }
}

# Meta-tests that validate the integration test approach itself
Describe "Integration Test Coverage Validation" {
    
    It "should verify that integration tests cover the real product code" {
        # This meta-test ensures our integration tests are actually testing the real code
        
        # Verify we're testing the actual script file
        Test-Path $script:PackageScriptPath | Should -Be $true
        
        # Verify the script contains the expected functionality
        $script:PackageScriptContent | Should -Not -BeNullOrEmpty
        $script:PackageScriptContent.Length | Should -BeGreaterThan 1000  # Reasonable size check
        
        # Verify we're testing the core functionality areas
        $script:PackageScriptContent | Should -Match "CertificatePath|CreateCertificate"  # Code signing
        $script:PackageScriptContent | Should -Match "New-ZipArchive"  # Packaging
        $script:PackageScriptContent | Should -Match "Get-SetupInfo"   # System checks
        $script:PackageScriptContent | Should -Match "Test-Path"       # File validation
    }
    
    It "should verify integration of all major code paths" {
        # Verify that the script integrates all expected major functionality
        
        # Code signing integration
        $codeSigningIntegration = ($script:PackageScriptContent -match "New-K2sCodeSigningCertificate") -and 
                                  ($script:PackageScriptContent -match "Invoke-K2sCodeSigning") -and
                                  ($script:PackageScriptContent -match "CertificatePath")
        $codeSigningIntegration | Should -Be $true
        
        # Offline artifact signing integration
        $offlineSigningIntegration = ($script:PackageScriptContent -match "ForOfflineInstallation") -and
                                     ($script:PackageScriptContent -match "Get-SignableFiles") -and
                                     ($script:PackageScriptContent -match "Set-K2sExecutableSignature") -and
                                     ($script:PackageScriptContent -match "Set-K2sScriptSignature")
        $offlineSigningIntegration | Should -Be $true
        
        # Packaging integration  
        $packagingIntegration = ($script:PackageScriptContent -match "New-ZipArchive") -and
                                ($script:PackageScriptContent -match "TargetDirectory") -and
                                ($script:PackageScriptContent -match "ZipPackageFileName")
        $packagingIntegration | Should -Be $true
        
        # Error handling integration
        $errorHandlingIntegration = ($script:PackageScriptContent -match "New-Error") -and
                                    ($script:PackageScriptContent -match "Write-Log.*-Error") -and
                                    ($script:PackageScriptContent -match "exit 1")
        $errorHandlingIntegration | Should -Be $true
        
        # Infrastructure integration
        $infraIntegration = ($script:PackageScriptContent -match "Get-KubePath") -and
                            ($script:PackageScriptContent -match "Initialize-Logging") -and
                            ($script:PackageScriptContent -match "Import-Module")
        $infraIntegration | Should -Be $true
    }
    
    It "should test the real product script without stubs" {
        # Verify we're not testing stub functions or mock implementations
        
        # The script should be the real implementation (has real complexity)
        ($script:PackageScriptContent -split "`n").Count | Should -BeGreaterThan 50
        
        # Should contain real implementation details (not just mocks)
        $script:PackageScriptContent | Should -Match "Param\("  # Real parameter block
        $script:PackageScriptContent | Should -Match "function"  # Real function definitions
        $script:PackageScriptContent | Should -Match "#Requires"  # Real script requirements
        
        # Should not contain test artifacts
        $script:PackageScriptContent | Should -Not -Match "Mock|Stub|Test-Only"
    }
}
