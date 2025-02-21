# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

# Load the module to be tested
Import-Module "$PSScriptRoot\config.module.psm1"

Describe "Get-MinimalProvisioningBaseMemorySize" {
    It "should return 2GB " {
        $result = Get-MinimalProvisioningBaseMemorySize       
        $result | Should -Be 2GB
    }
}

Describe "Get-MinimalProvisioningBaseImageDiskSize" {
    It "should return 10GB" {
        $result = Get-MinimalProvisioningBaseImageDiskSize        
        $result | Should -Be 10GB
    }
}