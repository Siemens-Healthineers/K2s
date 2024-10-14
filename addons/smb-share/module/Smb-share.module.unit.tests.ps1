# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
    $module = "$PSScriptRoot\Smb-share.module.psm1"

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
    $moduleName = (Import-Module $module -PassThru -Force).Name

    Import-Module "$PSScriptRoot\..\..\..\lib\modules\k2s\k2s.infra.module\errors\errors.module.psm1" -Force
}

Describe 'Test-CsiPodsCondition' -Tag 'unit', 'ci', 'addon', 'smb-share' {
    Context 'Condition invalid' {
        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Test-CsiPodsCondition -Condition 'invalid' } | Should -Throw
            }
        }
    }

    Context 'Linux-only' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-SetupInfo { return [pscustomobject]@{LinuxOnly = $true } }
        }

        Context 'default values' {
            Context 'Linux node Pod not running' {
                BeforeAll {
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $false } -ParameterFilter {
                        $Condition -eq 'Ready' -and $Label -eq 'app=csi-smb-node' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 0 }
                }

                It 'returns $false' {
                    InModuleScope -ModuleName $moduleName {
                        Test-CsiPodsCondition | Should -BeFalse
                    }
                }
            }

            Context 'controller Pod not running' {
                BeforeAll {
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Ready' -and $Label -eq 'app=csi-smb-node' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 0 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $false } -ParameterFilter {
                        $Condition -eq 'Ready' -and $Label -eq 'app=csi-smb-controller' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 0 }
                }

                It 'returns $false' {
                    InModuleScope -ModuleName $moduleName {
                        Test-CsiPodsCondition | Should -BeFalse
                    }
                }
            }

            Context 'all Pods running' {
                BeforeAll {
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Ready' -and $Label -eq 'app=csi-smb-node' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 0 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Ready' -and $Label -eq 'app=csi-smb-controller' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 0 }
                }

                It 'returns $true' {
                    InModuleScope -ModuleName $moduleName {
                        Test-CsiPodsCondition | Should -BeTrue
                    }
                }
            }
        }

        Context 'custom values' {
            Context 'Linux node Pod not deleted' {
                BeforeAll {
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $false } -ParameterFilter {
                        $Condition -eq 'Deleted' -and $Label -eq 'app=csi-smb-node' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 123 }
                }

                It 'returns $false' {
                    InModuleScope -ModuleName $moduleName {
                        Test-CsiPodsCondition -Condition 'Deleted' -TimeoutSeconds 123 | Should -BeFalse
                    }
                }
            }

            Context 'controller Pod not deleted' {
                BeforeAll {
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Deleted' -and $Label -eq 'app=csi-smb-node' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 123 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $false } -ParameterFilter {
                        $Condition -eq 'Deleted' -and $Label -eq 'app=csi-smb-controller' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 123 }
                }

                It 'returns $false' {
                    InModuleScope -ModuleName $moduleName {
                        Test-CsiPodsCondition -Condition 'Deleted' -TimeoutSeconds 123 | Should -BeFalse
                    }
                }
            }

            Context 'all Pods deleted' {
                BeforeAll {
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Deleted' -and $Label -eq 'app=csi-smb-node' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 123 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Deleted' -and $Label -eq 'app=csi-smb-controller' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 123 }
                }

                It 'returns $true' {
                    InModuleScope -ModuleName $moduleName {
                        Test-CsiPodsCondition -Condition 'Deleted' -TimeoutSeconds 123 | Should -BeTrue
                    }
                }
            }
        }
    }

    Context 'not Linux-only' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-SetupInfo { return [pscustomobject]@{LinuxOnly = $false } }
        }

        Context 'default values' {
            Context 'Windows node Pod not running' {
                BeforeAll {
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Ready' -and $Label -eq 'app=csi-smb-node' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 0 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Ready' -and $Label -eq 'app=csi-smb-controller' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 0 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $false } -ParameterFilter {
                        $Condition -eq 'Ready' -and $Label -eq 'app=csi-smb-node-win' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 0 }
                }

                It 'returns $false' {
                    InModuleScope -ModuleName $moduleName {
                        Test-CsiPodsCondition | Should -BeFalse
                    }
                }
            }

            Context 'proxy Pod not running' {
                BeforeAll {
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Ready' -and $Label -eq 'app=csi-smb-node' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 0 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Ready' -and $Label -eq 'app=csi-smb-controller' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 0 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Ready' -and $Label -eq 'app=csi-smb-node-win' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 0 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $false } -ParameterFilter {
                        $Condition -eq 'Ready' -and $Label -eq 'k8s-app=csi-proxy' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 0 }
                }

                It 'returns $false' {
                    InModuleScope -ModuleName $moduleName {
                        Test-CsiPodsCondition | Should -BeFalse
                    }
                }
            }

            Context 'all Pods running' {
                BeforeAll {
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Ready' -and $Label -eq 'app=csi-smb-node' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 0 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Ready' -and $Label -eq 'app=csi-smb-controller' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 0 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Ready' -and $Label -eq 'app=csi-smb-node-win' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 0 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Ready' -and $Label -eq 'k8s-app=csi-proxy' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 0 }
                }

                It 'returns $true' {
                    InModuleScope -ModuleName $moduleName {
                        Test-CsiPodsCondition | Should -BeTrue
                    }
                }
            }
        }

        Context 'custom values' {
            Context 'Windows node Pod not deleted' {
                BeforeAll {
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Deleted' -and $Label -eq 'app=csi-smb-node' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 123 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Deleted' -and $Label -eq 'app=csi-smb-controller' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 123 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $false } -ParameterFilter {
                        $Condition -eq 'Deleted' -and $Label -eq 'app=csi-smb-node-win' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 123 }
                }

                It 'returns $false' {
                    InModuleScope -ModuleName $moduleName {
                        Test-CsiPodsCondition -Condition 'Deleted' -TimeoutSeconds 123 | Should -BeFalse
                    }
                }
            }

            Context 'proxy Pod not deleted' {
                BeforeAll {
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Deleted' -and $Label -eq 'app=csi-smb-node' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 123 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Deleted' -and $Label -eq 'app=csi-smb-controller' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 123 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Deleted' -and $Label -eq 'app=csi-smb-node-win' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 123 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $false } -ParameterFilter {
                        $Condition -eq 'Deleted' -and $Label -eq 'k8s-app=csi-proxy' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 123 }
                }

                It 'returns $false' {
                    InModuleScope -ModuleName $moduleName {
                        Test-CsiPodsCondition -Condition 'Deleted' -TimeoutSeconds 123 | Should -BeFalse
                    }
                }
            }

            Context 'all Pods deleted' {
                BeforeAll {
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Deleted' -and $Label -eq 'app=csi-smb-node' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 123 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Deleted' -and $Label -eq 'app=csi-smb-controller' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 123 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Deleted' -and $Label -eq 'app=csi-smb-node-win' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 123 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Deleted' -and $Label -eq 'k8s-app=csi-proxy' -and $Namespace -eq 'kube-system' -and $TimeoutSeconds -eq 123 }
                }

                It 'returns $true' {
                    InModuleScope -ModuleName $moduleName {
                        Test-CsiPodsCondition -Condition 'Deleted' -TimeoutSeconds 123 | Should -BeTrue
                    }
                }
            }
        }
    }
}

Describe 'Test-IsSmbShareWorking' -Tag 'unit', 'ci', 'addon', 'smb-share' {
    Context 'Setup type is invalid' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-SetupInfo { return [pscustomobject]@{Name = 'invalid'; Error = 'setup type invalid' } }
        }

        It 'throws' {
            InModuleScope $moduleName {
                { Test-IsSmbShareWorking } | Should -Throw -ExpectedMessage 'setup type invalid'
            }
        }
    }

    Context "Setup type is neither 'k2s' nor 'MultiVMK8s'" {
        BeforeAll {
            Mock -ModuleName $moduleName Get-SetupInfo { return [pscustomobject]@{Name = 'TrippleK8s' } }
        }

        It 'throws' {
            InModuleScope $moduleName {
                { Test-IsSmbShareWorking } | Should -Throw -ExpectedMessage "*invalid setup type 'TrippleK8s'"
            }
        }
    }

    Context 'Setup type is k2s' {
        Context 'SMB share is not working' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-SetupInfo { return [pscustomobject]@{Name = 'k2s'; LinuxOnly = $false } }
                Mock -ModuleName $moduleName Test-SharedFolderMountOnWinNode {
                    InModuleScope -ModuleName $moduleName {
                        $script:Success = $false
                    }
                }
                Mock -ModuleName $moduleName Open-RemoteSessionViaSSHKey { throw 'unexpected' }
                Mock -ModuleName $moduleName Invoke-Command { throw 'unexpected' }
            }

            It 'returns false' {
                InModuleScope $moduleName {
                    Test-IsSmbShareWorking

                    $script:SmbShareWorking | Should -BeFalse
                }
            }
        }

        Context 'SMB share is working' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-SetupInfo { return [pscustomobject]@{Name = 'k2s'; LinuxOnly = $false } }
                Mock -ModuleName $moduleName Test-SharedFolderMountOnWinNode {
                    InModuleScope -ModuleName $moduleName {
                        $script:Success = $true
                    }
                }
                Mock -ModuleName $moduleName Open-RemoteSessionViaSSHKey { throw 'unexpected' }
                Mock -ModuleName $moduleName Invoke-Command { throw 'unexpected' }
            }

            It 'returns true' {
                InModuleScope $moduleName {
                    Test-IsSmbShareWorking

                    $script:SmbShareWorking | Should -BeTrue
                }
            }
        }
    }

    Context 'Setup type is MultiVM' {
        Context 'is Linux-only' {
            Context 'SMB share is not working' {
                BeforeAll {
                    Mock -ModuleName $moduleName Get-SetupInfo { return [pscustomobject]@{Name = 'MultiVMK8s'; LinuxOnly = $true } }
                    Mock -ModuleName $moduleName Test-SharedFolderMountOnWinNode {
                        InModuleScope -ModuleName $moduleName {
                            $script:Success = $false
                        }
                    }
                    Mock -ModuleName $moduleName Open-RemoteSessionViaSSHKey { throw 'unexpected' }
                    Mock -ModuleName $moduleName Invoke-Command { throw 'unexpected' }
                }

                It 'returns false' {
                    InModuleScope $moduleName {
                        Test-IsSmbShareWorking

                        $script:SmbShareWorking | Should -BeFalse
                    }
                }
            }

            Context 'SMB share is working' {
                BeforeAll {
                    Mock -ModuleName $moduleName Get-SetupInfo { return [pscustomobject]@{Name = 'MultiVMK8s'; LinuxOnly = $true } }
                    Mock -ModuleName $moduleName Test-SharedFolderMountOnWinNode {
                        InModuleScope -ModuleName $moduleName {
                            $script:Success = $true
                        }
                    }
                    Mock -ModuleName $moduleName Open-RemoteSessionViaSSHKey { throw 'unexpected' }
                    Mock -ModuleName $moduleName Invoke-Command { throw 'unexpected' }
                }

                It 'returns true' {
                    InModuleScope $moduleName {
                        Test-IsSmbShareWorking

                        $script:SmbShareWorking | Should -BeTrue
                    }
                }
            }
        }

        Context 'is not Linux-only' {
            Context 'SMB share is not working on Win VM' {
                BeforeAll {
                    Mock -ModuleName $moduleName Get-SetupInfo { return [pscustomobject]@{Name = 'MultiVMK8s'; LinuxOnly = $false } }
                    Mock -ModuleName $moduleName Test-SharedFolderMountOnWinNode {
                        InModuleScope -ModuleName $moduleName {
                            $script:Success = $true
                        }
                    }

                    Mock -ModuleName $moduleName Open-DefaultWinVMRemoteSessionViaSSHKey { } 
                    Mock -ModuleName $moduleName Invoke-Command { return $false } -RemoveParameterValidation 'Session'
                }

                It 'returns false' {
                    InModuleScope $moduleName {
                        Test-IsSmbShareWorking

                        $script:SmbShareWorking | Should -BeFalse
                    }
                }
            }

            Context 'SMB share is not working on Win host' {
                BeforeAll {
                    Mock -ModuleName $moduleName Get-SetupInfo { return [pscustomobject]@{Name = 'MultiVMK8s'; LinuxOnly = $false } }
                    Mock -ModuleName $moduleName Test-SharedFolderMountOnWinNode {
                        InModuleScope -ModuleName $moduleName {
                            $script:Success = $false
                        }
                    }

                    Mock -ModuleName $moduleName Open-DefaultWinVMRemoteSessionViaSSHKey { } 
                    Mock -ModuleName $moduleName Invoke-Command { return $true } -RemoveParameterValidation 'Session'
                }

                It 'returns false' {
                    InModuleScope $moduleName {
                        Test-IsSmbShareWorking

                        $script:SmbShareWorking | Should -BeFalse
                    }
                }
            }

            Context 'SMB share is working' {
                BeforeAll {
                    Mock -ModuleName $moduleName Get-SetupInfo { return [pscustomobject]@{Name = 'MultiVMK8s'; LinuxOnly = $false } }
                    Mock -ModuleName $moduleName Test-SharedFolderMountOnWinNode {
                        InModuleScope -ModuleName $moduleName {
                            $script:Success = $true
                        }
                    }

                    Mock -ModuleName $moduleName Open-DefaultWinVMRemoteSessionViaSSHKey { }
                    Mock -ModuleName $moduleName Invoke-Command { return $true } -RemoveParameterValidation 'Session'
                }

                It 'returns true' {
                    InModuleScope $moduleName {
                        Test-IsSmbShareWorking

                        $script:SmbShareWorking | Should -BeTrue
                    }
                }
            }
        }
    }
}

Describe 'New-SmbHostOnWindowsIfNotExisting' -Tag 'unit', 'ci', 'addon', 'smb-share' {
    Context 'SMB share already existing' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-SmbShare { return $true }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'does nothing' {
            InModuleScope $moduleName {
                New-SmbHostOnWindowsIfNotExisting
                Should -Invoke Write-Log -Times 1 -Scope Context -ParameterFilter { $Messages -match 'nothing to create' }
            }
        }
    }

    Context 'SMB share non-existent' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-SmbShare { return $null }
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName New-LocalUser { }
            Mock -ModuleName $moduleName New-Item { }
            Mock -ModuleName $moduleName New-SmbShare { }
            Mock -ModuleName $moduleName Add-FirewallExceptions { }

            InModuleScope $moduleName {
                New-SmbHostOnWindowsIfNotExisting
            }
        }

        It 'creates a local SMB user' {
            InModuleScope $moduleName {
                Should -Invoke New-LocalUser -Times 1 -Scope Context
            }
        }

        It 'creates a local SMB directory' {
            InModuleScope $moduleName {
                Should -Invoke New-Item -Times 1 -ParameterFilter { $ItemType -eq 'directory' } -Scope Context
            }
        }

        It 'creates a local SMB share' {
            InModuleScope $moduleName {
                Should -Invoke New-SmbShare -Times 1 -Scope Context
            }
        }

        It 'adds firewall exceptions' {
            InModuleScope $moduleName {
                Should -Invoke Add-FirewallExceptions -Times 1 -Scope Context
            }
        }
    }
}

Describe 'Remove-SmbHostOnWindowsIfExisting' -Tag 'unit', 'ci', 'addon', 'smb-share' {
    Context 'SMB share non-existent' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-SmbShare { return $null }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'does nothing' {
            InModuleScope $moduleName {
                Remove-SmbHostOnWindowsIfExisting

                Should -Invoke Write-Log -Times 1 -Scope Context -ParameterFilter { $Messages[0] -match 'nothing to remove' }
            }
        }
    }

    Context 'SMB share existing' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-SmbShare { return $true }
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Remove-LocalUser { }
            Mock -ModuleName $moduleName Remove-Item { }
            Mock -ModuleName $moduleName Remove-SmbShare { }
            Mock -ModuleName $moduleName Remove-FirewallExceptions { }

            InModuleScope $moduleName {
                Remove-SmbHostOnWindowsIfExisting
            }
        }

        It 'removes the local SMB user' {
            InModuleScope $moduleName {
                Should -Invoke Remove-LocalUser -Times 1 -Scope Context
            }
        }

        It 'removes the local SMB directory' {
            InModuleScope $moduleName {
                Should -Invoke Remove-Item -Times 1 -Scope Context
            }
        }

        It 'removes the local SMB share' {
            InModuleScope $moduleName {
                Should -Invoke Remove-SmbShare -Times 1 -Scope Context
            }
        }

        It 'removes firewall exceptions' {
            InModuleScope $moduleName {
                Should -Invoke Remove-FirewallExceptions -Times 1 -Scope Context
            }
        }
    }
}

Describe 'Restore-SmbShareAndFolderWindowsHost' -Tag 'unit', 'ci', 'addon', 'smb-share' {
    Context 'SMB share access already working' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Test-SharedFolderMountOnWinNode {
                InModuleScope -ModuleName $moduleName {
                    $script:Success = $true
                }
            }

            InModuleScope -ModuleName $moduleName {
                Restore-SmbShareAndFolderWindowsHost
            }
        }

        It 'does not mount anything' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Log -Times 1 -Scope Context -ParameterFilter { $Messages[0] -match 'nothing to do' }
            }
        }
    }

    Context 'SMB share not working yet' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Test-SharedFolderMountOnWinNode {
                InModuleScope -ModuleName $moduleName {
                    if ($script:testFlag -eq $true) {
                        $script:Success = $true
                    }
                    else {
                        $script:Success = $false
                        $script:testFlag = $true
                    }
                }
            }
            Mock -ModuleName $moduleName New-SmbHostOnWindowsIfNotExisting {}
            Mock -ModuleName $moduleName New-SharedFolderMountOnLinuxClient {}
            Mock -ModuleName $moduleName Wait-ForSharedFolderMountOnLinuxClient {}

            InModuleScope -ModuleName $moduleName {
                Restore-SmbShareAndFolderWindowsHost
            }
        }

        It 'creates SMB host on Windows' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke New-SmbHostOnWindowsIfNotExisting -Times 1 -Scope Context
            }
        }

        It 'creates SMB mount on Linux' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke New-SharedFolderMountOnLinuxClient -Times 1 -Scope Context
            }
        }

        It 'waits for SMB mount becoming available on Linux' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Wait-ForSharedFolderMountOnLinuxClient -Times 1 -Scope Context
            }
        }

        Context 'mount failed on Linux' {
            BeforeAll {
                Mock -ModuleName $moduleName Test-SharedFolderMountOnWinNode {
                    InModuleScope -ModuleName $moduleName {
                        $script:Success = $false
                    }
                }
            }

            It 'throws' {
                InModuleScope -ModuleName $moduleName {
                    { Restore-SmbShareAndFolderWindowsHost } | Should -Throw
                }
            }
        }
    }
}

Describe 'New-StorageClassManifest' -Tag 'unit', 'ci', 'addon', 'smb-share' {
    Context 'RemotePath not specified' {
        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { New-StorageClassManifest } | Should -Throw -ExpectedMessage 'RemotePath not specified'
            }
        }
    }

    Context 'invalid template' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-Content { return 'invalid content' }
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Convert-ToUnixPath {}
        }

        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { New-StorageClassManifest -RemotePath 'path' } | Should -Throw -ExpectedMessage 'value section not found in template file'
            }
        }
    }

    Context 'valid template' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-Content { return 'line1', 'value:', 'line 3' } -ParameterFilter { $Path -match '\\manifests\\base\\*' }
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Convert-ToUnixPath { return 'unix-path' } -ParameterFilter { $Path -eq 'remote-path' }
            Mock -ModuleName $moduleName Set-Content {}
        }

        It 'replaces path value from template and creates new manifest file' {
            InModuleScope -ModuleName $moduleName {
                New-StorageClassManifest -RemotePath 'remote-path'

                Should -Invoke Set-Content -Times 1 -Scope Context -ParameterFilter { $Path -match '\\manifests\\base\\*' -and $Value[1] -match "  value: `"unix-path`"" }
            }
        }
    }
}

Describe 'Wait-ForStorageClassToBeReady' -Tag 'unit', 'ci', 'addon', 'smb-share' {
    Context 'success' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Test-CsiPodsCondition { return $true } -ParameterFilter { $Condition -eq 'Ready' -and $TimeoutSeconds -eq 123 }
        }

        It 'does not throw' {
            InModuleScope -ModuleName $moduleName {
                { Wait-ForStorageClassToBeReady -TimeoutSeconds 123 } | Should -Not -Throw
            }
        }
    }

    Context 'failure' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Test-CsiPodsCondition { return $false } -ParameterFilter { $Condition -eq 'Ready' -and $TimeoutSeconds -eq 123 }
        }

        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Wait-ForStorageClassToBeReady -TimeoutSeconds 123 } | Should -Throw -ExpectedMessage 'StorageClass not ready within 123s'
            }
        }
    }
}

Describe 'Wait-ForStorageClassToBeDeleted' -Tag 'unit', 'ci', 'addon', 'smb-share' {
    Context 'success' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Test-CsiPodsCondition { return $true } -ParameterFilter { $Condition -eq 'Deleted' -and $TimeoutSeconds -eq 123 }
        }

        It 'does not throw' {
            InModuleScope -ModuleName $moduleName {
                { Wait-ForStorageClassToBeDeleted -TimeoutSeconds 123 } | Should -Not -Throw
            }
        }
    }

    Context 'failure' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Test-CsiPodsCondition { return $false } -ParameterFilter { $Condition -eq 'Deleted' -and $TimeoutSeconds -eq 123 }
        }

        It 'logs that it failed' {
            InModuleScope -ModuleName $moduleName {
                Wait-ForStorageClassToBeDeleted -TimeoutSeconds 123 
                
                Should -Invoke Write-Log -Times 1 -Scope Context -ParameterFilter { $Messages -match 'StorageClass not deleted within 123s' }                
            }
        }
    }
}

Describe 'Restore-StorageClass' -Tag 'unit', 'ci', 'addon', 'smb-share' {
    BeforeAll {
        Mock -ModuleName $moduleName Add-Secret {}
        Mock -ModuleName $moduleName New-StorageClassManifest {}
        Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{Success = $true } }
        Mock -ModuleName $moduleName Wait-ForStorageClassToBeReady {}
        Mock -ModuleName $moduleName Write-Log {}
    }

    Context 'SmbHostType invalid' {
        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Restore-StorageClass -SmbHostType 'invalid' } | Should -Throw
            }
        }
    }

    Context 'all succeeds' {
        BeforeAll {
            InModuleScope -ModuleName $moduleName {
                Restore-StorageClass -SmbHostType 'Windows'
            }
        }

        It 'creates SMB creds secret' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Add-Secret -Times 1 -Scope Context -ParameterFilter {
                    $Name -eq $script:smbCredsName -and $Namespace -eq 'kube-system' -and $Literals -contains "username=$script:smbUserName" -and $Literals -contains "password=$($creds.GetNetworkCredential().Password)"
                }
            }
        }

        It 'waits for the StorageClass creation' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Wait-ForStorageClassToBeReady -Times 1 -Scope Context -ParameterFilter { $TimeoutSeconds -eq $script:storageClassTimeoutSeconds }
            }
        }
    }

    Context 'Windows host type' {
        BeforeAll {
            InModuleScope -ModuleName $moduleName {
                Restore-StorageClass -SmbHostType 'Windows'
            }
        }

        It 'creates a new SC manifest file containing the Windows remote path' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke New-StorageClassManifest -Times 1 -Scope Context -ParameterFilter { $RemotePath -eq $script:windowsHostRemotePath }
            }
        }
    }

    Context 'Linux host type' {
        BeforeAll {
            InModuleScope -ModuleName $moduleName {
                Restore-StorageClass -SmbHostType 'Linux'
            }
        }

        It 'creates a new SC manifest file containing the Linux remote path' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke New-StorageClassManifest -Times 1 -Scope Context -ParameterFilter { $RemotePath -eq $script:linuxHostRemotePath }
            }
        }
    }

    Context 'not Linux-only' {
        It 'applies the manifest files from Windows folder' {
            InModuleScope -ModuleName $moduleName {
                Restore-StorageClass -SmbHostType 'Windows'

                Should -Invoke Invoke-Kubectl -Times 1 -Scope Context -ParameterFilter {
                    $Params -contains 'apply' -and $Params -contains '-k' -and $Params[2] -match '\\manifests\\windows'
                }
            }
        }
    }

    Context 'Linux-only' {
        It 'applies the manifest files from base folder' {
            InModuleScope -ModuleName $moduleName {
                Restore-StorageClass -SmbHostType 'Windows' -LinuxOnly $true

                Should -Invoke Invoke-Kubectl -Times 1 -Scope Context -ParameterFilter {
                    $Params -contains 'apply' -and $Params -contains '-k' -and $Params[2] -match '\\manifests\\base'
                }
            }
        }
    }

    Context 'Invoke-Kubectl failes' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{Output = 'oops'; Success = $false } }
        }

        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Restore-StorageClass -SmbHostType 'Windows' } | Should -Throw -ExpectedMessage 'oops'
            }
        }
    }
}

Describe 'Remove-StorageClass' -Tag 'unit', 'ci', 'addon', 'smb-share' {
    Context 'Manifest file found' {
        BeforeAll {
            Mock -ModuleName $moduleName Remove-PersistentVolumeClaimsForStorageClass {}
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -match $script:patchFilePath }
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{Success = $true } }
            Mock -ModuleName $moduleName Remove-Item {}
            Mock -ModuleName $moduleName Wait-ForStorageClassToBeDeleted {}
            Mock -ModuleName $moduleName Remove-Secret {}
            Mock -ModuleName $moduleName Write-Log {}

            InModuleScope -ModuleName $moduleName {
                Remove-StorageClass
            }
        }

        Context 'not Linux-only' {
            BeforeAll {
                InModuleScope -ModuleName $moduleName {
                    Remove-StorageClass
                }
            }

            It 'removes PVCs related to the SC' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Remove-PersistentVolumeClaimsForStorageClass -Times 1 -Scope Context -ParameterFilter {
                        $StorageClass -eq $script:smbStorageClassName
                    }
                }
            }

            It 'deletes resources from windows manifests folder' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Invoke-Kubectl -Times 1 -Scope Context -ParameterFilter {
                        $Params -contains 'delete' -and $Params -contains '-k' -and $Params[2] -match '\\manifests\\windows'
                    }
                }
            }

            It 'deletes the manifest file' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Remove-Item -Times 1 -Scope Context -ParameterFilter { $Path -match '\\manifests\\base' }
                }
            }

            It 'waits for StorageClass deletion' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Wait-ForStorageClassToBeDeleted -Times 1 -Scope Context -ParameterFilter { $TimeoutSeconds -eq $script:storageClassTimeoutSeconds }
                }
            }

            It 'deletes the SMB creds secret' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Remove-Secret -Times 1 -Scope Context -ParameterFilter { $Name -eq $script:smbCredsName -and $Namespace -eq 'kube-system' }
                }
            }
        }

        Context 'Linux-only' {
            BeforeAll {
                InModuleScope -ModuleName $moduleName {
                    Remove-StorageClass -LinuxOnly $true
                }
            }

            It 'removes PVCs related to the SC' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Remove-PersistentVolumeClaimsForStorageClass -Times 1 -Scope Context -ParameterFilter {
                        $StorageClass -eq $script:smbStorageClassName
                    }
                }
            }

            It 'deletes resources from base manifesst folder' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Invoke-Kubectl -Times 1 -Scope Context -ParameterFilter {
                        $Params -contains 'delete' -and $Params -contains '-k' -and $Params[2] -match '\\manifests\\base'
                    }
                }
            }

            It 'waits for StorageClass deletion' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Wait-ForStorageClassToBeDeleted -Times 1 -Scope Context -ParameterFilter { { $TimeoutSeconds -eq $script:storageClassTimeoutSeconds } }
                }
            }

            It 'deletes the manifest file' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Remove-Item -Times 1 -Scope Context -ParameterFilter { $Path -match '\\manifests\\base' }
                }
            }

            It 'deletes the SMB creds secret' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Remove-Secret -Times 1 -Scope Context -ParameterFilter { $Name -eq $script:smbCredsName -and $Namespace -eq 'kube-system' }
                }
            }
        }

        Context 'Invoke-Kubectl failes' {
            BeforeAll {
                Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{Output = 'oops'; Success = $false } }
                Mock -ModuleName $moduleName Write-Warning { }
            }

            It 'logs a warning' {
                InModuleScope -ModuleName $moduleName {
                    Remove-StorageClass

                    Should -Invoke Write-Warning -Times 1 -Scope Context -ParameterFilter { $Message -match 'oops' }
                }
            }
        }
    }

    Context 'Manifest file missing' {
        BeforeAll {
            Mock -ModuleName $moduleName Remove-PersistentVolumeClaimsForStorageClass {}
            Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $Path -match $script:patchFilePath }
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Remove-Secret {}

            InModuleScope -ModuleName $moduleName {
                Remove-StorageClass
            }
        }

        It 'removes PVCs related to the SC' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Remove-PersistentVolumeClaimsForStorageClass -Times 1 -Scope Context -ParameterFilter {
                    $StorageClass -eq $script:smbStorageClassName
                }
            }
        }

        It 'skips resource and file deletion' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Log -Times 1 -Scope Context -ParameterFilter { $Messages -match 'manifest already deleted' }
            }
        }

        It 'deletes the SMB creds secret' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Remove-Secret -Times 1 -Scope Context -ParameterFilter { $Name -eq $script:smbCredsName -and $Namespace -eq 'kube-system' }
            }
        }
    }
}

Describe 'Remove-SmbShareAndFolderWindowsHost' -Tag 'unit', 'ci', 'addon', 'smb-share' {
    Context 'nodes cleanup skipped' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Remove-SharedFolderMountOnLinuxClient {}
            Mock -ModuleName $moduleName Remove-SmbHostOnWindowsIfExisting {}

            InModuleScope -ModuleName $moduleName {
                Remove-SmbShareAndFolderWindowsHost -SkipNodesCleanup
            }
        }

        It 'does not cleanup the Linux node' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Remove-SharedFolderMountOnLinuxClient -Times 0 -Scope Context
                Should -Invoke Remove-SmbHostOnWindowsIfExisting -Times 1 -Scope Context
            }
        }
    }

    Context 'nodes cleanup not skipped' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Remove-SharedFolderMountOnLinuxClient {}
            Mock -ModuleName $moduleName Remove-SmbHostOnWindowsIfExisting {}

            InModuleScope -ModuleName $moduleName {
                Remove-SmbShareAndFolderWindowsHost
            }
        }

        It 'cleanups up the Linux node' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Remove-SharedFolderMountOnLinuxClient -Times 1 -Scope Context
                Should -Invoke Remove-SmbHostOnWindowsIfExisting -Times 1 -Scope Context
            }
        }
    }
}

Describe 'Restore-SmbShareAndFolderLinuxHost' -Tag 'unit', 'ci', 'addon', 'smb-share' {
    Context 'testing skipped' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Wait-ForSharedFolderOnLinuxHost {
                InModuleScope -ModuleName $moduleName { $script:Success = $true }
            }
            Mock -ModuleName $moduleName Test-SharedFolderMountOnWinNode {
                InModuleScope -ModuleName $moduleName { $script:Success = $true }
            }
            Mock -ModuleName $moduleName New-SmbHostOnLinuxIfNotExisting {}
            Mock -ModuleName $moduleName New-SharedFolderMountOnLinuxHost {}
            Mock -ModuleName $moduleName New-SharedFolderMountOnWindows {}

            InModuleScope -ModuleName $moduleName {
                Restore-SmbShareAndFolderLinuxHost -SkipTest
            }
        }

        It 'creates SMB share and mount' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Wait-ForSharedFolderOnLinuxHost -Times 1 -Scope Context
                Should -Invoke Test-SharedFolderMountOnWinNode -Times 1 -Scope Context
                Should -Invoke New-SmbHostOnLinuxIfNotExisting -Times 1 -Scope Context
                Should -Invoke New-SharedFolderMountOnLinuxHost -Times 1 -Scope Context
                Should -Invoke New-SharedFolderMountOnWindows -Times 1 -Scope Context
            }
        }
    }

    Context 'testing not skipped' {
        Context 'everything already working' {
            BeforeAll {
                Mock -ModuleName $moduleName Write-Log {}
                Mock -ModuleName $moduleName Wait-ForSharedFolderOnLinuxHost {
                    InModuleScope -ModuleName $moduleName {
                        $script:Success = $true
                    }
                }
                Mock -ModuleName $moduleName Test-SharedFolderMountOnWinNode {
                    InModuleScope -ModuleName $moduleName {
                        $script:Success = $true
                    }
                }

                InModuleScope -ModuleName $moduleName {
                    Restore-SmbShareAndFolderLinuxHost
                }
            }

            It 'does not mount anything' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Write-Log -Times 1 -ParameterFilter { $Messages[0] -match 'nothing to restore' } -Scope Context
                }
            }
        }

        Context 'SMB share on Linux not working' {
            BeforeAll {
                Mock -ModuleName $moduleName Write-Log {}
                Mock -ModuleName $moduleName Wait-ForSharedFolderOnLinuxHost {
                    InModuleScope -ModuleName $moduleName {
                        if ($script:testFlag2 -eq $true) {
                            $script:Success = $true
                        }
                        else {
                            $script:Success = $false
                            $script:testFlag2 = $true
                        }
                    }
                }
                Mock -ModuleName $moduleName Test-SharedFolderMountOnWinNode {
                    InModuleScope -ModuleName $moduleName {
                        $script:Success = $true
                    }
                }
                Mock -ModuleName $moduleName New-SmbHostOnLinuxIfNotExisting {}
                Mock -ModuleName $moduleName New-SharedFolderMountOnLinuxHost {}
                Mock -ModuleName $moduleName New-SharedFolderMountOnWindows {}

                InModuleScope -ModuleName $moduleName {
                    Restore-SmbShareAndFolderLinuxHost
                }
            }

            It 'creates SMB share and mount' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke New-SmbHostOnLinuxIfNotExisting -Times 1 -Scope Context
                    Should -Invoke New-SharedFolderMountOnLinuxHost -Times 1 -Scope Context
                    Should -Invoke New-SharedFolderMountOnWindows -Times 1 -Scope Context
                }
            }
        }

        Context 'SMB mount on Windows not working' {
            BeforeAll {
                Mock -ModuleName $moduleName Write-Log {}
                Mock -ModuleName $moduleName Wait-ForSharedFolderOnLinuxHost {
                    InModuleScope -ModuleName $moduleName {
                        $script:Success = $true
                    }
                }
                Mock -ModuleName $moduleName Test-SharedFolderMountOnWinNode {
                    InModuleScope -ModuleName $moduleName {
                        if ($script:testFlag3 -eq $true) {
                            $script:Success = $true
                        }
                        else {
                            $script:Success = $false
                            $script:testFlag3 = $true
                        }
                    }
                }
                Mock -ModuleName $moduleName New-SmbHostOnLinuxIfNotExisting {}
                Mock -ModuleName $moduleName New-SharedFolderMountOnLinuxHost {}
                Mock -ModuleName $moduleName New-SharedFolderMountOnWindows {}

                InModuleScope -ModuleName $moduleName {
                    Restore-SmbShareAndFolderLinuxHost
                }
            }

            It 'creates SMB share and mount' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke New-SmbHostOnLinuxIfNotExisting -Times 1 -Scope Context
                    Should -Invoke New-SharedFolderMountOnLinuxHost -Times 1 -Scope Context
                    Should -Invoke New-SharedFolderMountOnWindows -Times 1 -Scope Context
                }
            }
        }
    }

    Context 'SMB share creation on Linux failed' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Wait-ForSharedFolderOnLinuxHost {
                InModuleScope -ModuleName $moduleName {
                    $script:Success = $false
                }
            }
            Mock -ModuleName $moduleName Test-SharedFolderMountOnWinNode {}
            Mock -ModuleName $moduleName New-SmbHostOnLinuxIfNotExisting {}
            Mock -ModuleName $moduleName New-SharedFolderMountOnLinuxHost {}
            Mock -ModuleName $moduleName New-SharedFolderMountOnWindows {}
        }

        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Restore-SmbShareAndFolderLinuxHost } | Should -Throw -ExpectedMessage 'Unable to mount shared folder with CIFS on Linux host'
            }
        }
    }

    Context 'SMB mount on Windows failed' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Wait-ForSharedFolderOnLinuxHost {
                InModuleScope -ModuleName $moduleName {
                    if ($script:testFlag4 -eq $true) {
                        $script:Success = $true
                    }
                    else {
                        $script:Success = $false
                        $script:testFlag4 = $true
                    }
                }
            }
            Mock -ModuleName $moduleName Test-SharedFolderMountOnWinNode {
                InModuleScope -ModuleName $moduleName {
                    $script:Success = $false
                }
            }
            Mock -ModuleName $moduleName New-SmbHostOnLinuxIfNotExisting {}
            Mock -ModuleName $moduleName New-SharedFolderMountOnLinuxHost {}
            Mock -ModuleName $moduleName New-SharedFolderMountOnWindows {}
        }

        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Restore-SmbShareAndFolderLinuxHost } | Should -Throw -ExpectedMessage "Unable to setup SMB share '$windowsLocalPath' on Linux host"
            }
        }
    }
}

Describe 'Remove-SmbShareAndFolderLinuxHost' -Tag 'unit', 'ci', 'addon', 'smb-share' {
    Context 'nodes cleanup skipped' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Remove-SmbGlobalMappingIfExisting {}
            Mock -ModuleName $moduleName Remove-LocalWinMountIfExisting {}
            Mock -ModuleName $moduleName Remove-SharedFolderMountOnLinuxHost {}
            Mock -ModuleName $moduleName Remove-SmbHostOnLinux {}
        }

        It 'does not remove mount and share host on Linux' {
            InModuleScope -ModuleName $moduleName {
                Remove-SmbShareAndFolderLinuxHost -SkipNodesCleanup

                Should -Invoke Remove-SmbGlobalMappingIfExisting -Times 1 -Scope Context
                Should -Invoke Remove-LocalWinMountIfExisting -Times 1 -Scope Context
                Should -Invoke Remove-SharedFolderMountOnLinuxHost -Times 0 -Scope Context
                Should -Invoke Remove-SmbHostOnLinux -Times 0 -Scope Context
            }
        }
    }

    Context 'nodes cleanup not skipped' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Remove-SmbGlobalMappingIfExisting {}
            Mock -ModuleName $moduleName Remove-LocalWinMountIfExisting {}
            Mock -ModuleName $moduleName Remove-SharedFolderMountOnLinuxHost {}
            Mock -ModuleName $moduleName Remove-SmbHostOnLinux {}
        }

        It 'does remove mount and share host on Linux' {
            InModuleScope -ModuleName $moduleName {
                Remove-SmbShareAndFolderLinuxHost

                Should -Invoke Remove-SmbGlobalMappingIfExisting -Times 1 -Scope Context
                Should -Invoke Remove-LocalWinMountIfExisting -Times 1 -Scope Context
                Should -Invoke Remove-SharedFolderMountOnLinuxHost -Times 1 -Scope Context
                Should -Invoke Remove-SmbHostOnLinux -Times 1 -Scope Context
            }
        }
    }
}

Describe 'Remove-SmbShareAndFolder' -Tag 'unit', 'ci', 'addon', 'smb-share' {
    Context 'nodes cleanup skipped' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Get-SmbHostType {}
            Mock -ModuleName $moduleName Get-SetupInfo {}
            Mock -ModuleName $moduleName Remove-StorageClass {}
            Mock -ModuleName $moduleName Remove-SmbShareAndFolderWindowsHost {}
            Mock -ModuleName $moduleName Remove-SmbShareAndFolderLinuxHost {}
            Mock -ModuleName $moduleName Remove-SharedFolderFromWinVM {}

            InModuleScope -ModuleName $moduleName {
                Remove-SmbShareAndFolder -SkipNodesCleanup
            }
        }

        It 'does not remove the StorageClass' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Remove-StorageClass -Times 0 -Scope Context
            }
        }

        It 'skips the Windows VM cleanup' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Remove-SharedFolderFromWinVM -Times 0 -Scope Context
            }
        }

        Context 'Windows host' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-SmbHostType { return 'Windows' }
                Mock -ModuleName $moduleName Get-SetupInfo {}
                Mock -ModuleName $moduleName Remove-SmbShareAndFolderWindowsHost {}
                Mock -ModuleName $moduleName Remove-SmbShareAndFolderLinuxHost { throw 'unexpected' }

                InModuleScope -ModuleName $moduleName {
                    Remove-SmbShareAndFolder -SkipNodesCleanup
                }
            }

            It 'propagates the skipped cleanup for Windows' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Remove-SmbShareAndFolderWindowsHost -Times 1 -Scope Context -ParameterFilter { $SkipNodesCleanup -eq $true }
                }
            }
        }

        Context 'Linux host' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-SmbHostType { return 'Linux' }
                Mock -ModuleName $moduleName Get-SetupInfo {}
                Mock -ModuleName $moduleName Remove-SmbShareAndFolderWindowsHost { throw 'unexpected' }
                Mock -ModuleName $moduleName Remove-SmbShareAndFolderLinuxHost {}

                InModuleScope -ModuleName $moduleName {
                    Remove-SmbShareAndFolder -SkipNodesCleanup
                }
            }

            It 'propagates the skipped cleanup for Linux' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Remove-SmbShareAndFolderLinuxHost -Times 1 -Scope Context -ParameterFilter { $SkipNodesCleanup -eq $true }
                }
            }
        }
    }

    Context 'nodes cleanup not skipped' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Get-SmbHostType { }
            Mock -ModuleName $moduleName Get-SetupInfo { return [pscustomobject]@{LinuxOnly = $false } }
            Mock -ModuleName $moduleName Remove-StorageClass {}
            Mock -ModuleName $moduleName Remove-SmbShareAndFolderWindowsHost {}
            Mock -ModuleName $moduleName Remove-SmbShareAndFolderLinuxHost {}
            Mock -ModuleName $moduleName Remove-SharedFolderFromWinVM {}

            InModuleScope -ModuleName $moduleName {
                Remove-SmbShareAndFolder
            }
        }

        It 'does remove StorageClass' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Remove-StorageClass -Times 1 -Scope Context -ParameterFilter { $LinuxOnly -eq $false }
            }
        }

        Context 'Linux-only' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-SetupInfo { return [pscustomobject]@{LinuxOnly = $true } }

                InModuleScope -ModuleName $moduleName {
                    Remove-SmbShareAndFolder
                }
            }

            It 'does not cleanup Windows VM' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Remove-SharedFolderFromWinVM -Times 0 -Scope Context
                }
            }

            It 'does remove StorageClass with Linux-only param set to $true' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Remove-StorageClass -Times 1 -Scope Context -ParameterFilter { $LinuxOnly -eq $true }
                }
            }
        }

        Context 'not Multivm, not Linux-only' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-SetupInfo { return [pscustomobject]@{LinuxOnly = $false; Name = 'not-multivm' } }

                InModuleScope -ModuleName $moduleName {
                    Remove-SmbShareAndFolder
                }
            }

            It 'does not cleanup Windows VM' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Remove-SharedFolderFromWinVM -Times 0 -Scope Context
                }
            }
        }

        Context 'Multivm, not Linux-only' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-SetupInfo { return [pscustomobject]@{LinuxOnly = $false; Name = 'MultiVMK8s' } }
            }

            Context 'Windows host' {
                BeforeAll {
                    Mock -ModuleName $moduleName Get-SmbHostType { return 'Windows' }

                    InModuleScope -ModuleName $moduleName {
                        Remove-SmbShareAndFolder
                    }
                }

                It 'performs cleanup Windows VM with Windows remote path' {
                    InModuleScope -ModuleName $moduleName {
                        Should -Invoke Remove-SharedFolderFromWinVM -Times 1 -Scope Context -ParameterFilter { $RemotePath -eq $windowsHostRemotePath }
                    }
                }
            }

            Context 'Linux host' {
                BeforeAll {
                    Mock -ModuleName $moduleName Get-SmbHostType { return 'Linux' }

                    InModuleScope -ModuleName $moduleName {
                        Remove-SmbShareAndFolder
                    }
                }

                It 'performs cleanup Windows VM with Linux remote path' {
                    InModuleScope -ModuleName $moduleName {
                        Should -Invoke Remove-SharedFolderFromWinVM -Times 1 -Scope Context -ParameterFilter { $RemotePath -eq $linuxHostRemotePath }
                    }
                }
            }
        }

        Context 'Windows host' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-SmbHostType { return 'Windows' }

                InModuleScope -ModuleName $moduleName {
                    Remove-SmbShareAndFolder
                }
            }

            It 'propagates the cleanup info for Windows' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Remove-SmbShareAndFolderWindowsHost -Times 1 -Scope Context -ParameterFilter { $SkipNodesCleanup -eq $false }
                }
            }
        }

        Context 'Linux host' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-SmbHostType { return 'Linux' }

                InModuleScope -ModuleName $moduleName {
                    Remove-SmbShareAndFolder
                }
            }

            It 'propagates the cleanup info for Linux' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Remove-SmbShareAndFolderLinuxHost -Times 1 -Scope Context -ParameterFilter { $SkipNodesCleanup -eq $false }
                }
            }
        }
    }
}

Describe 'Enable-SmbShare' -Tag 'unit', 'ci', 'addon', 'smb-share' {
    Context 'SMB host type not set' {
        It 'throws' {
            { Enable-SmbShare } | Should -Throw -ExpectedMessage 'SMB host type not set'
        }
    }

    Context 'invalid SMB host type' {
        It 'throws' {
            { Enable-SmbShare -SmbHostType 'invalid' } | Should -Throw
        }
    }

    Context 'system is not running' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-SystemAvailability { return @{Code = 'unavailable' } }
        }

        It 'returns error' {
            (Enable-SmbShare -SmbHostType 'Windows').Error.Code | Should -Be 'unavailable'
        }
    }

    Context 'addon is already enabled' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-SystemAvailability { }
            Mock -ModuleName $moduleName Test-IsAddonEnabled { return $true } -ParameterFilter { $Name -eq $AddonName }
        }

        It 'returns error' {
            InModuleScope -ModuleName $moduleName {
                $err = (Enable-SmbShare -SmbHostType 'Windows').Error
                
                $err.Severity | Should -Be Warning
                $err.Code | Should -Be (Get-ErrCodeAddonAlreadyEnabled) 
                $err.Message | Should -Match 'already enabled'
            }
        }
    }

    Context 'addon is disabled' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-SystemAvailability { }
            Mock -ModuleName $moduleName Test-IsAddonEnabled { return $false } -ParameterFilter { $Name -eq $AddonName }
        }

        Context 'setup type invalid for this addon' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-SetupInfo { return [pscustomobject]@{Name = 'invalid-type' } }
            }

            It 'returns error' {
                $err = (Enable-SmbShare -SmbHostType 'Linux').Error
                     
                $err.Severity | Should -Be Warning
                $err.Code | Should -Be (Get-ErrCodeWrongSetupType)
                $err.Message | Should -Match 'can only be enabled for'
            }
        }

        Context 'setup type valid for this addon' {
            BeforeAll {
                $setupInfo = [pscustomobject]@{Name = 'k2s'; LinuxOnly = $true }

                Mock -ModuleName $moduleName Get-SetupInfo { return $setupInfo }
                Mock -ModuleName $moduleName Copy-ScriptsToHooksDir { }
                Mock -ModuleName $moduleName Add-AddonToSetupJson { }
                Mock -ModuleName $moduleName Restore-SmbShareAndFolder { }
                Mock -ModuleName $moduleName Restore-StorageClass { }
                Mock -ModuleName $moduleName Write-Log { }
            }

            It 'enables the addon passing the correct params' {
                InModuleScope -ModuleName $moduleName {
                    $smbHostType = 'Linux'

                    $result = Enable-SmbShare -SmbHostType $smbHostType

                    $result.Error | Should -BeNullOrEmpty

                    Should -Invoke Copy-ScriptsToHooksDir -Times 1 -Scope Context
                    Should -Invoke Add-AddonToSetupJson -Times 1 -Scope Context -ParameterFilter { $Addon.Name -eq $AddonName -and $Addon.SmbHostType -eq $smbHostType }
                    Should -Invoke Restore-SmbShareAndFolder -Times 1 -Scope Context -ParameterFilter {
                        $SmbHostType -eq $smbHostType -and $SkipTest -eq $true -and $SetupInfo.Name -eq 'k2s' -and $SetupInfo.LinuxOnly -eq $true
                    }
                    Should -Invoke Restore-StorageClass -Times 1 -Scope Context -ParameterFilter { $SmbHostType -eq $smbHostType -and $LinuxOnly -eq $true }
                }
            }
        }
    }
}

Describe 'Disable-SmbShare' -Tag 'unit', 'ci', 'addon', 'smb-share' {
    Context 'node cleanup skipped' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Test-IsAddonEnabled { return $false }
            Mock -ModuleName $moduleName Test-SystemAvailability { }
        }

        It 'does not test system availability' {
            InModuleScope -ModuleName $moduleName {
                $err = (Disable-SmbShare -SkipNodesCleanup).Error
                
                $err.Severity | Should -Be Warning
                $err.Code | Should -Be (Get-ErrCodeAddonAlreadyDisabled)
                $err.Message | Should -Match 'already disabled'
                
                Should -Invoke Test-SystemAvailability -Times 0 -Scope Context
            }
        }
    }

    Context 'system available' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-SystemAvailability { return $null }
            Mock -ModuleName $moduleName Test-IsAddonEnabled { return $false }
        }

        It 'does not return system error' {
            InModuleScope -ModuleName $moduleName {
                $err = (Disable-SmbShare).Error
                
                $err.Severity | Should -Be Warning
                $err.Code | Should -Be (Get-ErrCodeAddonAlreadyDisabled)
                $err.Message | Should -Match 'already disabled'
            }
        }
    }        
    
    Context 'system unavailable' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-SystemAvailability { return @{Code = 'err-code'; Message = 'err-msg' } }
        }

        It 'returns error' {
            InModuleScope -ModuleName $moduleName {
                $err = (Disable-SmbShare).Error
                
                $err.Code | Should -Be 'err-code'
                $err.Message | Should -Be 'err-msg'
            }
        }
    }  

    Context 'addon already disabled' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-SystemAvailability { return $null }
            Mock -ModuleName $moduleName Test-IsAddonEnabled { return $false }
        }

        It 'returns error' {
            InModuleScope -ModuleName $moduleName {
                $err = (Disable-SmbShare).Error
                    
                $err.Severity | Should -Be Warning
                $err.Code | Should -Be (Get-ErrCodeAddonAlreadyDisabled)
                $err.Message | Should -Match 'already disabled'
            }
        }
    }

    Context 'addon enabled' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-IsAddonEnabled { return $true }
            Mock -ModuleName $moduleName Remove-SmbShareAndFolder { }
            Mock -ModuleName $moduleName Remove-AddonFromSetupJson { }
            Mock -ModuleName $moduleName Remove-ScriptsFromHooksDir { }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'disables the addon with skip flag set correctly' {
            InModuleScope -ModuleName $moduleName {
                $err = (Disable-SmbShare -SkipNodesCleanup).Error
                
                $err | Should -BeNullOrEmpty

                Should -Invoke Remove-SmbShareAndFolder -Times 1 -Scope Context -ParameterFilter { $SkipNodesCleanup -eq $true }
                Should -Invoke Remove-AddonFromSetupJson -Times 1 -Scope Context -ParameterFilter { $Name -eq $AddonName }
                Should -Invoke Remove-ScriptsFromHooksDir -Times 1 -Scope Context
            }
        }
    }
}

Describe 'Restore-SmbShareAndFolder' -Tag 'unit', 'ci', 'addon', 'smb-share' {
    Context 'SMB host type not set' {
        It 'throws' {
            { Restore-SmbShareAndFolder } | Should -Throw
        }
    }

    Context 'SMB host type invalid' {
        It 'throws' {
            { Restore-SmbShareAndFolder -SmbHostType 'invalid' } | Should -Throw
        }
    }

    Context 'Windows host' {
        BeforeAll {
            Mock -ModuleName $moduleName Restore-SmbShareAndFolderWindowsHost {}
        }

        It 'calls Windows-specific restore function skipping the tests' {
            InModuleScope -ModuleName $moduleName {
                Restore-SmbShareAndFolder -SmbHostType 'Windows' -SkipTest

                Should -Invoke Restore-SmbShareAndFolderWindowsHost -Times 1 -Scope Context -ParameterFilter { $SkipTest -eq $true }
            }
        }

        It 'calls Windows-specific restore function not skipping the tests' {
            InModuleScope -ModuleName $moduleName {
                Restore-SmbShareAndFolder -SmbHostType 'Windows'

                Should -Invoke Restore-SmbShareAndFolderWindowsHost -Times 1 -Scope Context -ParameterFilter { $SkipTest -eq $false }
            }
        }

        Context 'setup type is not multi-vm' {
            BeforeAll {
                Mock -ModuleName $moduleName Add-SharedFolderToWinVM { }
            }

            It 'does not mount SMB share on Windows VM' {
                InModuleScope -ModuleName $moduleName {
                    Restore-SmbShareAndFolder -SmbHostType 'Windows'

                    Should -Invoke Add-SharedFolderToWinVM -Times 0 -Scope Context
                }
            }
        }

        Context 'setup type is multi-vm and not Linux-only' {
            BeforeAll {
                Mock -ModuleName $moduleName Add-SharedFolderToWinVM { }
            }

            It 'mounts SMB share on Windows VM' {
                InModuleScope -ModuleName $moduleName {
                    Restore-SmbShareAndFolder -SmbHostType 'Windows' -SetupInfo ([pscustomobject]@{Name = 'MultiVMK8s' })

                    Should -Invoke Add-SharedFolderToWinVM -Times 1 -Scope Context -ParameterFilter { $SmbHostType -eq 'Windows' }
                }
            }
        }
    }

    Context 'Linux host' {
        BeforeAll {
            Mock -ModuleName $moduleName Restore-SmbShareAndFolderLinuxHost {}
        }

        It 'calls Linux-specific restore function skipping the tests' {
            InModuleScope -ModuleName $moduleName {
                Restore-SmbShareAndFolder -SmbHostType 'Linux' -SkipTest

                Should -Invoke Restore-SmbShareAndFolderLinuxHost -Times 1 -Scope Context -ParameterFilter { $SkipTest -eq $true }
            }
        }

        It 'calls Linux-specific restore function not skipping the tests' {
            InModuleScope -ModuleName $moduleName {
                Restore-SmbShareAndFolder -SmbHostType 'Linux'

                Should -Invoke Restore-SmbShareAndFolderLinuxHost -Times 1 -Scope Context -ParameterFilter { $SkipTest -eq $false }
            }
        }

        Context 'setup type is not multi-vm' {
            BeforeAll {
                Mock -ModuleName $moduleName Add-SharedFolderToWinVM { }
            }

            It 'does not mount SMB share on Windows VM' {
                InModuleScope -ModuleName $moduleName {
                    Restore-SmbShareAndFolder -SmbHostType 'Linux'

                    Should -Invoke Add-SharedFolderToWinVM -Times 0 -Scope Context
                }
            }
        }

        Context 'setup type is multi-vm and not Linux-only' {
            BeforeAll {
                Mock -ModuleName $moduleName Add-SharedFolderToWinVM { }
            }

            It 'mounts SMB share on Windows VM' {
                InModuleScope -ModuleName $moduleName {
                    Restore-SmbShareAndFolder -SmbHostType 'Linux' -SetupInfo ([pscustomobject]@{Name = 'MultiVMK8s' })

                    Should -Invoke Add-SharedFolderToWinVM -Times 1 -Scope Context -ParameterFilter { $SmbHostType -eq 'Linux' }
                }
            }
        }
    }
}

Describe 'Get-SmbHostType' -Tag 'unit', 'ci', 'addon', 'smb-share' {
    BeforeAll {
        Mock -ModuleName $moduleName Get-AddonConfig { return [PSCustomObject]@{Name = 'addon1'; SmbHOstType = 'my-type' } } -ParameterFilter { $Name -match $AddonName }
    }

    It 'returns SMB host' {
        InModuleScope $moduleName {
            Get-SmbHostType | Should -Be 'my-type'
        }
    }
}

Describe 'Connect-WinVMClientToSmbHost' -Tag 'unit', 'ci', 'addon', 'smb-share' {
    Context 'SMB host type is Windows' {
        BeforeAll {
            Mock -ModuleName $moduleName New-SharedFolderMountOnWindows {}
        }
        It 'joins Win VM SMB client with Win host SMB server' {
            Connect-WinVMClientToSmbHost -SmbHostType 'Windows'

            InModuleScope -ModuleName $moduleName {
                Should -Invoke New-SharedFolderMountOnWindows -Times 1 -ParameterFilter { $RemotePath -eq $windowsHostRemotePath -and $SmbUser -eq $smbFullUserNameWin -and $SmbPasswd -eq $smbPw }
            }
        }
    }
    Context 'SMB host type is Linux' {
        BeforeAll {
            Mock -ModuleName $moduleName New-SharedFolderMountOnWindows {}
        }
        It 'joins Win VM SMB client with Linux host SMB server' {
            Connect-WinVMClientToSmbHost -SmbHostType 'Linux'

            InModuleScope -ModuleName $moduleName {
                Should -Invoke New-SharedFolderMountOnWindows -Times 1 -ParameterFilter { $RemotePath -eq $linuxHostRemotePath -and $SmbUser -eq $smbFullUserNameLinux -and $SmbPasswd -eq $smbPw }
            }
        }
    }
    Context 'SMB host type is invalid' {
        It 'throws' {
            { Connect-WinVMClientToSmbHost } | Should -Throw
        }
    }
}

Describe 'Test-SharedFolderMountOnWinNodeSilently' -Tag 'unit', 'ci', 'addon', 'smb-share' {
    Context 'Test-SharedFolderMountOnWinNode signals success' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-SharedFolderMountOnWinNode {
                InModuleScope -ModuleName $moduleName {
                    $script:Success = $true
                }
            }
        }

        It "returns $true" {
            InModuleScope -ModuleName $moduleName {
                Test-SharedFolderMountOnWinNodeSilently | Should -BeTrue
            }
        }
    }

    Context 'Test-SharedFolderMountOnWinNode signals failure' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-SharedFolderMountOnWinNode {
                InModuleScope -ModuleName $moduleName {
                    $script:Success = $false
                }
            }
        }
        It "returns $false" {
            InModuleScope -ModuleName $moduleName {
                Test-SharedFolderMountOnWinNodeSilently | Should -BeFalse
            }
        }
    }
}

Describe 'Get-Status' -Tag 'unit', 'ci', 'addon', 'smb-share' {  
    BeforeAll {
        Mock -ModuleName $moduleName Get-SmbHostType { return 'my-type' } 
    }
          
    Context 'always' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-IsSmbShareWorking {}
            Mock -ModuleName $moduleName Test-CsiPodsCondition {}

            InModuleScope -ModuleName $moduleName {
                $script:result = Get-Status
            }
        }

        It 'returns SMB host type' {
            InModuleScope -ModuleName $moduleName {
                $script:result[0].Name | Should -Be 'SmbHostType'
                $script:result[0].Value | Should -Be 'my-type'
                $script:result[0].Message | Should -BeNullOrEmpty
                $script:result[0].Okay | Should -BeNullOrEmpty
            }
        }
    }

    Context 'SMB share is not working' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-IsSmbShareWorking {
                InModuleScope -ModuleName $moduleName {
                    $script:SmbShareWorking = $false
                }
            }
            Mock -ModuleName $moduleName Test-CsiPodsCondition {}

            InModuleScope -ModuleName $moduleName {
                $script:result = Get-Status
            }
        }

        It 'returns not-working status' {
            InModuleScope -ModuleName $moduleName {
                $script:result[1].Name | Should -Be 'IsSmbShareWorking'
                $script:result[1].Value | Should -BeFalse
                $script:result[1].Message | Should -Match 'is not working'
                $script:result[1].Okay | Should -BeFalse
            }
        }
    }
   
    Context 'SMB share is working' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-IsSmbShareWorking {
                InModuleScope -ModuleName $moduleName {
                    $script:SmbShareWorking = $true
                }
            }
            Mock -ModuleName $moduleName Test-CsiPodsCondition {}

            InModuleScope -ModuleName $moduleName {
                $script:result = Get-Status
            }
        }

        It 'returns is-working status' {
            InModuleScope -ModuleName $moduleName {
                $script:result[1].Name | Should -Be 'IsSmbShareWorking'
                $script:result[1].Value | Should -BeTrue
                $script:result[1].Message | Should -Match 'is working'
                $script:result[1].Okay | Should -BeTrue
            }
        }
    }

    Context 'Pods are not running' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-IsSmbShareWorking {}
            Mock -ModuleName $moduleName Test-CsiPodsCondition { return $false } -ParameterFilter { $Condition -eq 'Ready' }

            InModuleScope -ModuleName $moduleName {
                $script:result = Get-Status
            }
        }

        It 'returns not-running status' {
            InModuleScope -ModuleName $moduleName {
                $script:result[2].Name | Should -Be 'AreCsiPodsRunning'
                $script:result[2].Value | Should -BeFalse
                $script:result[2].Message | Should -Match 'are not running'
                $script:result[2].Okay | Should -BeFalse
            }
        }
    }
  
    Context 'Pods are running' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-IsSmbShareWorking {}
            Mock -ModuleName $moduleName Test-CsiPodsCondition { return $true } -ParameterFilter { $Condition -eq 'Ready' }

            InModuleScope -ModuleName $moduleName {
                $script:result = Get-Status
            }
        }

        It 'returns are-running status' {
            InModuleScope -ModuleName $moduleName {
                $script:result[2].Name | Should -Be 'AreCsiPodsRunning'
                $script:result[2].Value | Should -BeTrue
                $script:result[2].Message | Should -Match 'are running'
                $script:result[2].Okay | Should -BeTrue
            }
        }
    }
}

Describe 'Backup-AddonData' -Tag 'unit', 'ci', 'addon', 'smb-share' {
    Context 'backup directory not specified' {
        It 'throws' {
            { Backup-AddonData } | Should -Throw -ExpectedMessage 'Please specify the back-up directory.'
        }
    }

    Context 'backup directory not existing' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $Path -eq "test-dir\$AddonName" }
            Mock -ModuleName $moduleName Test-Path { throw 'unexpected' } -ParameterFilter { $Path -ne "test-dir\$AddonName" }
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName New-Item { }
            Mock -ModuleName $moduleName Copy-Item { }

            InModuleScope -ModuleName $moduleName {
                Backup-AddonData -BackupDir 'test-dir'
            }
        }

        It 'gets created' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke New-Item -Times 1 -ParameterFilter { $Path -eq "test-dir\$AddonName" -and $ItemType -eq 'Directory' } -Scope Context
            }
        }
    }

    Context 'backup directory specified' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -eq "test-dir\$AddonName" }
            Mock -ModuleName $moduleName Test-Path { throw 'unexpected' } -ParameterFilter { $Path -ne "test-dir\$AddonName" }
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Copy-Item { }

            InModuleScope -ModuleName $moduleName {
                Backup-AddonData -BackupDir 'test-dir'
            }
        }

        It 'data gets copied' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Copy-Item -Times 1 -ParameterFilter { $Path -eq "$windowsLocalPath\*" -and $Destination -eq "test-dir\$AddonName" } -Scope Context
            }
        }
    }
}

Describe 'Restore-AddonData'-Tag 'unit', 'ci', 'addon', 'smb-share' {
    Context 'backup directory not specified' {
        It 'throws' {
            { Restore-AddonData } | Should -Throw -ExpectedMessage 'Please specify the back-up directory.'
        }
    }

    Context 'backup directory not existing' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $Path -eq "test-dir\$AddonName" }
            Mock -ModuleName $moduleName Test-Path { throw 'unexpected' } -ParameterFilter { $Path -ne "test-dir\$AddonName" }
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Copy-Item { }

            InModuleScope -ModuleName $moduleName {
                Restore-AddonData -BackupDir 'test-dir'
            }
        }

        It 'notifies the user' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Log -Times 1 -ParameterFilter { $Messages[0] -match 'not existing, skipping' } -Scope Context
            }
        }

        It 'skips the restore' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Copy-Item -Times 0 -Scope Context
            }
        }
    }

    Context 'backup directory existing' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -eq "test-dir\$AddonName" }
            Mock -ModuleName $moduleName Test-Path { throw 'unexpected' } -ParameterFilter { $Path -ne "test-dir\$AddonName" }
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Copy-Item { }

            InModuleScope -ModuleName $moduleName {
                Restore-AddonData -BackupDir 'test-dir'
            }
        }

        It 'restores the data' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Copy-Item -Times 1 -ParameterFilter { $Path -eq "test-dir\$AddonName\*" -and $Destination -eq $windowsLocalPath } -Scope Context
            }
        }
    }
}

Describe 'Remove-SmbGlobalMappingIfExisting' -Tag 'unit', 'ci', 'addon', 'smb-share' {
    Context 'remote path not specified' {
        It 'throws' {
            { Remove-SmbGlobalMappingIfExisting } | Should -Throw -ExpectedMessage 'RemotePath not specified'
        }
    }

    Context 'mapping non-existent' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Get-SmbGlobalMapping { return $null } -ParameterFilter { $RemotePath -eq 'test-path' }
            Mock -ModuleName $moduleName Get-SmbGlobalMapping { throw 'unexpected' } -ParameterFilter { $RemotePath -ne 'test-path' }
            Mock -ModuleName $moduleName Remove-SmbGlobalMapping { }

            InModuleScope -ModuleName $moduleName {
                Remove-SmbGlobalMappingIfExisting -RemotePath 'test-path'
            }
        }

        It 'skips the removal' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Log -Times 1 -Scope Context -ParameterFilter { $Messages[0] -match 'not existing, nothing to remove' }
                Should -Invoke Remove-SmbGlobalMapping -Times 0 -Scope Context
            }
        }
    }

    Context 'mapping existnet' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Get-SmbGlobalMapping { return 'existent' } -ParameterFilter { $RemotePath -eq 'test-path' }
            Mock -ModuleName $moduleName Get-SmbGlobalMapping { throw 'unexpected' } -ParameterFilter { $RemotePath -ne 'test-path' }
            Mock -ModuleName $moduleName Remove-SmbGlobalMapping { }

            InModuleScope -ModuleName $moduleName {
                Remove-SmbGlobalMappingIfExisting -RemotePath 'test-path'
            }
        }

        It 'removes the mapping' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Remove-SmbGlobalMapping -Times 1 -Scope Context -ParameterFilter { $RemotePath -eq 'test-path' }
            }
        }
    }
}

Describe 'Remove-LocalWinMountIfExisting' -Tag 'unit', 'ci', 'addon', 'smb-share' {
    Context 'local mount not existing' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $false }
            Mock -ModuleName $moduleName Write-Log {}

            InModuleScope -ModuleName $moduleName {
                Remove-LocalWinMountIfExisting
            }
        }

        It 'skips the removal' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Log -Times 1 -Scope Context -ParameterFilter { $Messages[0] -match 'not existing, nothing to remove' }
            }
        }
    }

    Context 'local mount is symbolic link' {
        BeforeAll {
            class Deleter {
                [void] Delete() { $this.Deleted = $true }
                [string]$LinkType = 'SymbolicLink'
                [bool]$Deleted = $false
            }

            $script:deleter = [Deleter]::new()

            Mock -ModuleName $moduleName Test-Path { return $true }
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Get-Item { return $script:deleter }

            InModuleScope -ModuleName $moduleName {
                Remove-LocalWinMountIfExisting
            }
        }

        It 'removes the link' {
            InModuleScope -ModuleName $moduleName -Parameters @{deleter = $script:deleter } {
                $deleter.Deleted | Should -BeTrue
            }
        }
    }

    Context 'local mount is directory' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $true }
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Get-Item { 'dir' }
            Mock -ModuleName $moduleName Remove-Item { }

            InModuleScope -ModuleName $moduleName {
                Remove-LocalWinMountIfExisting
            }
        }

        It 'removes the directory' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Remove-Item -Times 1 -Scope Context
            }
        }
    }
}