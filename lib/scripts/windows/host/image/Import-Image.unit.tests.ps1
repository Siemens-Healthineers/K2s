# SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

BeforeAll {
    $modulePath = "$PSScriptRoot/Image-Common.module.psm1"
    $moduleName = (Import-Module $modulePath -PassThru -Force).Name
}

Describe 'Image import helpers' -Tag 'unit', 'ci', 'image' {
    It 'returns preflight failures instead of exiting when return-status mode is requested' {
        InModuleScope $moduleName {
            Mock Test-SystemAvailability { [PSCustomObject]@{ Message = 'cluster unavailable' } }

            $result = Initialize-ImageScriptContext -ReturnStatus

            $result | Should -BeFalse
        }
    }

    It 'reports a failed Linux remote import using the result Success property and attempts cleanup' {
        InModuleScope $moduleName {
            Mock Copy-ToRemoteComputerViaSshKey {}
            $script:remoteCommandCount = 0
            Mock Invoke-CmdOnVmViaSSHKey {
                $script:remoteCommandCount++
                if ($script:remoteCommandCount -eq 1) {
                    return [PSCustomObject]@{ Success = $false; Output = 'remote import failed' }
                }
                return [PSCustomObject]@{ Success = $true; Output = '' }
            }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'image.tar' -NodeInfo @{
                Kind = 'LinuxWorker'
                Name = 'worker-1'
                Username = 'k2s'
                IpAddress = '192.0.2.1'
            }

            $result | Should -BeFalse
            $script:remoteCommandCount | Should -Be 2
            Should -Invoke Invoke-CmdOnVmViaSSHKey -Times 2 -Exactly
        }
    }

    It 'reports Linux copy exceptions, skips import, and still attempts remote cleanup' {
        InModuleScope $moduleName {
            Mock Copy-ToRemoteComputerViaSshKey { throw 'copy failed' }
            Mock Invoke-CmdOnVmViaSSHKey {
                [PSCustomObject]@{ Success = $true; Output = '' }
            }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'image.tar' -NodeInfo @{
                Kind = 'LinuxWorker'
                Name = 'worker-1'
                Username = 'k2s'
                IpAddress = '192.0.2.1'
            }

            $result | Should -BeFalse
            Should -Invoke Invoke-CmdOnVmViaSSHKey -Times 1 -Exactly
        }
    }

    It 'does not treat ctr output plus a false status as a successful import' {
        InModuleScope $moduleName {
            $result = Test-ImageImportSuccess -Result @('ctr import failed', $false)

            $result | Should -BeFalse
            (Test-ImageImportSuccess -Result ([PSCustomObject]@{ Success = $false; Output = 'ctr import failed' })) | Should -BeFalse
            (Test-ImageImportSuccess -Result ([PSCustomObject]@{ Success = $true; Output = '' })) | Should -BeTrue
        }
    }

}