# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
    $module = "$PSScriptRoot\Smb-posix.module.psm1"

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
    $moduleName = (Import-Module $module -PassThru -Force).Name
}

Describe 'Test-SambaPosixNegotiation' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    # The posix module does not import the infra module, so
    # Invoke-CmdOnControlPlaneViaSSHKey is unresolved in its scope. Each test
    # injects a stub of that command inside the module scope to return canned
    # testparm output, then exercises the validator against it.

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
                # First attempt: smbd still restarting (no POSIX settings yet).
                # Second attempt: settings now serviceable -> validator should succeed.
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
