# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
    $module = "$PSScriptRoot\Smb-posix.module.psm1"

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
    $moduleName = (Import-Module $module -PassThru -Force).Name
}

Describe 'Smb-posix module dependency resolution' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    # Regression guard (#2478): asserts the module imports its node-module dependency so the cmdlet resolves at runtime. Injects NO stub on purpose.
    Context 'Required cmdlet is in scope after import' {
        It 'resolves Invoke-CmdOnControlPlaneViaSSHKey inside the posix module scope' {
            InModuleScope -ModuleName $moduleName {
                Get-Command -Name 'Invoke-CmdOnControlPlaneViaSSHKey' -ErrorAction SilentlyContinue |
                    Should -Not -BeNullOrEmpty
            }
        }
    }
}

Describe 'Test-SambaPosixNegotiation' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    # Each test stubs Invoke-CmdOnControlPlaneViaSSHKey in module scope with canned testparm output for host-free validation.

    Context 'POSIX settings present in testparm output' {
        It 'returns true when streams_xattr and store dos attributes = no are configured' {
            InModuleScope -ModuleName $moduleName {
                function Invoke-CmdOnControlPlaneViaSSHKey {
                    param([string]$CmdToExecute, [int]$Timeout, [switch]$NoLog)
                    return [pscustomobject]@{
                        Output = @('vfs objects = streams_xattr', 'store dos attributes = no')
                    }
                }

                Test-SambaPosixNegotiation -ShareName 'k2s-smb-share' | Should -BeTrue
            }
        }
    }

    Context 'POSIX settings missing' {
        It 'returns false when streams_xattr is absent' {
            InModuleScope -ModuleName $moduleName {
                function Invoke-CmdOnControlPlaneViaSSHKey {
                    param([string]$CmdToExecute, [int]$Timeout, [switch]$NoLog)
                    return [pscustomobject]@{ Output = @('store dos attributes = no') }
                }

                Test-SambaPosixNegotiation -ShareName 'k2s-smb-share' | Should -BeFalse
            }
        }

        It 'returns false when store dos attributes setting is absent' {
            InModuleScope -ModuleName $moduleName {
                function Invoke-CmdOnControlPlaneViaSSHKey {
                    param([string]$CmdToExecute, [int]$Timeout, [switch]$NoLog)
                    return [pscustomobject]@{ Output = @('vfs objects = streams_xattr') }
                }

                Test-SambaPosixNegotiation -ShareName 'k2s-smb-share' | Should -BeFalse
            }
        }
    }

    Context 'Bounded retry while smbd becomes ready' {
        It 'retries and returns true once POSIX settings appear on a later attempt' {
            InModuleScope -ModuleName $moduleName {
                # First attempt: smbd still restarting; second attempt: settings serviceable.
                $script:posixAttempt = 0
                function Invoke-CmdOnControlPlaneViaSSHKey {
                    param([string]$CmdToExecute, [int]$Timeout, [switch]$NoLog)
                    $script:posixAttempt++
                    if ($script:posixAttempt -lt 2) {
                        return [pscustomobject]@{ Output = @('# smbd not ready') }
                    }
                    return [pscustomobject]@{
                        Output = @('vfs objects = streams_xattr', 'store dos attributes = no')
                    }
                }
                # Stub the backoff so the test does not actually wait.
                function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) }

                Test-SambaPosixNegotiation -ShareName 'k2s-smb-share' -Retries 5 -RetryDelaySeconds 1 | Should -BeTrue
                $script:posixAttempt | Should -BeGreaterOrEqual 2
            }
        }

        It 'returns false after exhausting the retry budget when settings never appear' {
            InModuleScope -ModuleName $moduleName {
                $script:posixCalls = 0
                function Invoke-CmdOnControlPlaneViaSSHKey {
                    param([string]$CmdToExecute, [int]$Timeout, [switch]$NoLog)
                    $script:posixCalls++
                    return [pscustomobject]@{ Output = @('# never ready') }
                }
                function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) }

                Test-SambaPosixNegotiation -ShareName 'k2s-smb-share' -Retries 3 -RetryDelaySeconds 1 | Should -BeFalse
                $script:posixCalls | Should -Be 3
            }
        }
    }

    Context 'Section query returns nothing' {
        It 'falls back to a full configuration dump and still detects POSIX settings' {
            InModuleScope -ModuleName $moduleName {
                function Invoke-CmdOnControlPlaneViaSSHKey {
                    param([string]$CmdToExecute, [int]$Timeout, [switch]$NoLog)
                    if ($CmdToExecute -match '--section-name') {
                        return [pscustomobject]@{ Output = @() }
                    }
                    return [pscustomobject]@{
                        Output = @('vfs objects = streams_xattr', 'store dos attributes = no')
                    }
                }

                Test-SambaPosixNegotiation -ShareName 'k2s-smb-share' | Should -BeTrue
            }
        }
    }
}

Describe 'Get-FstabVersionOption' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    # AC#1 (#2478): an 'auto' or empty dialect must resolve to a concrete fstab vers= so the host mount succeeds.
    Context 'auto or empty dialect' {
        It 'defaults to the host fstab dialect for auto' {
            InModuleScope -ModuleName $moduleName {
                Get-FstabVersionOption -SmbDialect 'auto' | Should -Be "vers=$script:DefaultSmbFstabDialect"
            }
        }

        It 'defaults to the host fstab dialect for an empty dialect' {
            InModuleScope -ModuleName $moduleName {
                Get-FstabVersionOption -SmbDialect '' | Should -Be "vers=$script:DefaultSmbFstabDialect"
            }
        }
    }

    Context 'explicit dialect' {
        It 'pins the requested dialect' {
            InModuleScope -ModuleName $moduleName {
                Get-FstabVersionOption -SmbDialect '3.1.1' | Should -Be 'vers=3.1.1'
            }
        }
    }

    # AC#1 (#2478): the Linux Samba host historically pinned 'vers=3'; an 'auto' dialect must not
    # downgrade it to 'vers=3.0' when a caller-specific default is supplied.
    Context 'caller-specific default dialect' {
        It 'uses the supplied default for auto' {
            InModuleScope -ModuleName $moduleName {
                Get-FstabVersionOption -SmbDialect 'auto' -DefaultDialect '3' | Should -Be 'vers=3'
            }
        }

        It 'still pins an explicit dialect regardless of the default' {
            InModuleScope -ModuleName $moduleName {
                Get-FstabVersionOption -SmbDialect '3.1.1' -DefaultDialect '3' | Should -Be 'vers=3.1.1'
            }
        }
    }
}

Describe 'Get-SambaSharePosixConfig' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    # AC#2c (#2478): POSIX shares must declare streams_xattr; non-POSIX shares must not.
    Context 'POSIX extensions enabled' {
        It 'returns the streams_xattr and store dos attributes settings' {
            InModuleScope -ModuleName $moduleName {
                $lines = Get-SambaSharePosixConfig -Config ([pscustomobject]@{ EnablePosixExtensions = $true })
                $lines | Should -Contain 'vfs objects = streams_xattr'
                $lines | Should -Contain 'store dos attributes = no'
            }
        }
    }

    Context 'POSIX extensions disabled' {
        It 'returns no POSIX share lines' {
            InModuleScope -ModuleName $moduleName {
                Get-SambaSharePosixConfig -Config ([pscustomobject]@{ EnablePosixExtensions = $false }) | Should -BeNullOrEmpty
            }
        }
    }
}
