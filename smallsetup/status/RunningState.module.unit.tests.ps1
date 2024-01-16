# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

BeforeAll {
    $module = "$PSScriptRoot\RunningState.module.psm1"

    $moduleName = (Import-Module $module -PassThru -Force).Name
}

Describe 'Get-VmState' -Tag 'unit' {
    Context 'VM name not specified' {
        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Get-VmState } | Should -Throw -ExpectedMessage 'VM name not specified'
            }
        }
    }
}

Describe 'Get-RunningState' -Tag 'unit' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log {}
    }

    Context 'setup type not specified' {
        It 'throws' {
            { Get-RunningState } | Should -Throw
        }
    }

    Context 'k2s setup type' {
        Context 'master on Linux VM' {
            Context 'everything is running' {
                BeforeAll {
                    Mock -ModuleName $moduleName Get-IsVmRunning { return $true } -ParameterFilter { $Name -eq 'kubemaster' }
                    Mock -ModuleName $moduleName Get-VmState { return 'Running' } -ParameterFilter { $Name -eq 'kubemaster' }
                    Mock -ModuleName $moduleName Get-VmState { throw 'wrong VM name' } -ParameterFilter { $Name -ne 'kubemaster' }
                    Mock -ModuleName $moduleName Get-Service { return @{Status = 'Running' } } -ParameterFilter { $Name -eq 'flanneld' -or $Name -eq 'kubelet' -or $Name -eq 'kubeproxy' }
                    Mock -ModuleName $moduleName Get-Service { throw 'wrong service name' } -ParameterFilter { $Name -ne 'flanneld' -and $Name -ne 'kubelet' -and $Name -ne 'kubeproxy' }
                    Mock -ModuleName $moduleName Get-ConfigValue { return $false } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'WSL' }
                }

                It 'returns all running without issues' {
                    $result = Get-RunningState -SetupType 'k2s'
                    $result.IsRunning | Should -BeTrue
                    $result.Issues | Should -BeNullOrEmpty
                }
            }

            Context 'VM is not running' {
                BeforeAll {
                    Mock -ModuleName $moduleName Get-IsVmRunning { return $false } -ParameterFilter { $Name -eq 'kubemaster' }
                    Mock -ModuleName $moduleName Get-VmState { return 'stopped' } -ParameterFilter { $Name -eq 'kubemaster' }
                    Mock -ModuleName $moduleName Get-VmState { throw 'wrong VM name' } -ParameterFilter { $Name -ne 'kubemaster' }
                    Mock -ModuleName $moduleName Get-Service { return @{Status = 'Running' } } -ParameterFilter { $Name -eq 'flanneld' -or $Name -eq 'kubelet' -or $Name -eq 'kubeproxy' }
                    Mock -ModuleName $moduleName Get-Service { throw 'wrong service name' } -ParameterFilter { $Name -ne 'flanneld' -and $Name -ne 'kubelet' -and $Name -ne 'kubeproxy' }
                    Mock -ModuleName $moduleName Get-ConfigValue { return $false } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'WSL' }
                }

                It 'returns not all running with VM issue' {
                    $result = Get-RunningState -SetupType 'k2s'
                    $result.IsRunning | Should -BeFalse
                    $result.Issues.Count | Should -Be 1
                    $result.Issues[0] | Should -Match 'kubemaster'
                    $result.Issues[0] | Should -Match 'not running'
                    $result.Issues[0] | Should -Match 'stopped'
                    $result.Issues[0] | Should -Match 'VM'
                }
            }

            Context 'flanneld is not running' {
                BeforeAll {
                    Mock -ModuleName $moduleName Get-IsVmRunning { return $true } -ParameterFilter { $Name -eq 'kubemaster' }
                    Mock -ModuleName $moduleName Get-VmState { return  'Running' } -ParameterFilter { $Name -eq 'kubemaster' }
                    Mock -ModuleName $moduleName Get-VmState { throw 'wrong VM name' } -ParameterFilter { $Name -ne 'kubemaster' }
                    Mock -ModuleName $moduleName Get-Service { return @{Status = 'Running' } } -ParameterFilter { $Name -eq 'kubelet' -or $Name -eq 'kubeproxy' }
                    Mock -ModuleName $moduleName Get-Service { return @{Status = 'stopped' } } -ParameterFilter { $Name -eq 'flanneld' }
                    Mock -ModuleName $moduleName Get-Service { throw 'wrong service name' } -ParameterFilter { $Name -ne 'flanneld' -and $Name -ne 'kubelet' -and $Name -ne 'kubeproxy' }
                    Mock -ModuleName $moduleName Get-ConfigValue { return $false } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'WSL' }
                }

                It 'returns not all running with flanneld issue' {
                    $result = Get-RunningState -SetupType 'k2s'
                    $result.IsRunning | Should -BeFalse
                    $result.Issues.Count | Should -Be 1
                    $result.Issues[0] | Should -Match 'flanneld'
                    $result.Issues[0] | Should -Match 'not running'
                    $result.Issues[0] | Should -Match 'service'
                }
            }

            Context 'nothing is running' {
                BeforeAll {
                    Mock -ModuleName $moduleName Get-IsVmRunning { return $false } -ParameterFilter { $Name -eq 'kubemaster' }
                    Mock -ModuleName $moduleName Get-VmState { return 'stopped' } -ParameterFilter { $Name -eq 'kubemaster' }
                    Mock -ModuleName $moduleName Get-VmState { throw 'wrong VM name' } -ParameterFilter { $Name -ne 'kubemaster' }
                    Mock -ModuleName $moduleName Get-Service { return @{Status = 'stopped' } } -ParameterFilter { $Name -eq 'flanneld' -or $Name -eq 'kubelet' -or $Name -eq 'kubeproxy' }
                    Mock -ModuleName $moduleName Get-Service { throw 'wrong service name' } -ParameterFilter { $Name -ne 'flanneld' -and $Name -ne 'kubelet' -and $Name -ne 'kubeproxy' }
                    Mock -ModuleName $moduleName Get-ConfigValue { return $false } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'WSL' }
                }

                It 'returns nothing running with all issues' {
                    $result = Get-RunningState -SetupType 'k2s'
                    $result.IsRunning | Should -BeFalse
                    $result.Issues.Count | Should -Be 4
                    $result.Issues[0] | Should -Match 'kubemaster'
                    $result.Issues[0] | Should -Match 'not running'
                    $result.Issues[0] | Should -Match 'stopped'
                    $result.Issues[0] | Should -Match 'VM'
                    $result.Issues[1] | Should -Match 'flanneld'
                    $result.Issues[1] | Should -Match 'not running'
                    $result.Issues[1] | Should -Match 'service'
                    $result.Issues[2] | Should -Match 'kubelet'
                    $result.Issues[2] | Should -Match 'not running'
                    $result.Issues[2] | Should -Match 'service'
                    $result.Issues[3] | Should -Match 'kubeproxy'
                    $result.Issues[3] | Should -Match 'not running'
                    $result.Issues[3] | Should -Match 'service'
                }
            }
        }

        Context 'master on WSL' {
            Context 'everything is running' {
                BeforeAll {
                    Mock -ModuleName $moduleName Get-IsWslRunning { return $true }
                    Mock -ModuleName $moduleName Get-Service { return @{Status = 'Running' } } -ParameterFilter { $Name -eq 'flanneld' -or $Name -eq 'kubelet' -or $Name -eq 'kubeproxy' }
                    Mock -ModuleName $moduleName Get-Service { throw 'wrong service name' } -ParameterFilter { $Name -ne 'flanneld' -and $Name -ne 'kubelet' -and $Name -ne 'kubeproxy' }
                    Mock -ModuleName $moduleName Get-ConfigValue { return $true } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'WSL' }
                }

                It 'returns all running without issues' {
                    $result = Get-RunningState -SetupType 'k2s'
                    $result.IsRunning | Should -BeTrue
                    $result.Issues | Should -BeNullOrEmpty
                }
            }

            Context 'WSL is not running' {
                BeforeAll {
                    Mock -ModuleName $moduleName Get-IsWslRunning { return $false }
                    Mock -ModuleName $moduleName Get-Service { return @{Status = 'Running' } } -ParameterFilter { $Name -eq 'flanneld' -or $Name -eq 'kubelet' -or $Name -eq 'kubeproxy' }
                    Mock -ModuleName $moduleName Get-Service { throw 'wrong service name' } -ParameterFilter { $Name -ne 'flanneld' -and $Name -ne 'kubelet' -and $Name -ne 'kubeproxy' }
                    Mock -ModuleName $moduleName Get-ConfigValue { return $true } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'WSL' }
                }

                It 'returns not all running with WSL issue' {
                    InModuleScope $moduleName {
                        $result = Get-RunningState -SetupType 'k2s'
                        $result.IsRunning | Should -BeFalse
                        $result.Issues.Count | Should -Be 1
                        $result.Issues[0] | Should -Match 'kubemaster'
                        $result.Issues[0] | Should -Match 'not running'
                        $result.Issues[0] | Should -Match 'WSL'
                    }
                }
            }

            Context 'flanneld is not running' {
                BeforeAll {
                    Mock -ModuleName $moduleName Get-IsWslRunning { return $true }
                    Mock -ModuleName $moduleName Get-Service { return @{Status = 'Running' } } -ParameterFilter { $Name -eq 'kubelet' -or $Name -eq 'kubeproxy' }
                    Mock -ModuleName $moduleName Get-Service { return @{Status = 'stopped' } } -ParameterFilter { $Name -eq 'flanneld' }
                    Mock -ModuleName $moduleName Get-Service { throw 'wrong service name' } -ParameterFilter { $Name -ne 'flanneld' -and $Name -ne 'kubelet' -and $Name -ne 'kubeproxy' }
                    Mock -ModuleName $moduleName Get-ConfigValue { return $true } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'WSL' }
                }

                It 'returns not all running with flanneld issue' {
                    $result = Get-RunningState -SetupType 'k2s'
                    $result.IsRunning | Should -BeFalse
                    $result.Issues.Count | Should -Be 1
                    $result.Issues[0] | Should -Match 'flanneld'
                    $result.Issues[0] | Should -Match 'not running'
                    $result.Issues[0] | Should -Match 'service'
                }
            }

            Context 'nothing is not running' {
                BeforeAll {
                    Mock -ModuleName $moduleName Get-IsWslRunning { return $false }
                    Mock -ModuleName $moduleName Get-Service { return @{Status = 'stopped' } } -ParameterFilter { $Name -eq 'flanneld' -or $Name -eq 'kubelet' -or $Name -eq 'kubeproxy' }
                    Mock -ModuleName $moduleName Get-Service { throw 'wrong service name' } -ParameterFilter { $Name -ne 'flanneld' -and $Name -ne 'kubelet' -and $Name -ne 'kubeproxy' }
                    Mock -ModuleName $moduleName Get-ConfigValue { return $true } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'WSL' }
                }

                It 'returns nothing running with all issues' {
                    $result = Get-RunningState -SetupType 'k2s'
                    $result.IsRunning | Should -BeFalse
                    $result.Issues.Count | Should -Be 4
                    $result.Issues[0] | Should -Match 'kubemaster'
                    $result.Issues[0] | Should -Match 'not running'
                    $result.Issues[0] | Should -Match 'WSL'
                    $result.Issues[1] | Should -Match 'flanneld'
                    $result.Issues[1] | Should -Match 'not running'
                    $result.Issues[1] | Should -Match 'service'
                    $result.Issues[2] | Should -Match 'kubelet'
                    $result.Issues[2] | Should -Match 'not running'
                    $result.Issues[2] | Should -Match 'service'
                    $result.Issues[3] | Should -Match 'kubeproxy'
                    $result.Issues[3] | Should -Match 'not running'
                    $result.Issues[3] | Should -Match 'service'
                }
            }
        }
    }

    Context 'MultiVMK8s setup type' {
        Context 'default multi-vm setup' {
            Context 'master on Linux VM' {
                Context 'everything is running' {
                    BeforeAll {
                        Mock -ModuleName $moduleName Get-IsVmRunning { return $true } -ParameterFilter { $Name -eq 'kubemaster' -or $Name -eq 'winnode' }
                        Mock -ModuleName $moduleName Get-VmState { return 'Running' } -ParameterFilter { $Name -eq 'kubemaster' -or $Name -eq 'winnode' }
                        Mock -ModuleName $moduleName Get-VmState { throw 'wrong VM name' } -ParameterFilter { $Name -ne 'kubemaster' -and $Name -ne 'winnode' }
                        Mock -ModuleName $moduleName Get-Service { throw 'must not be invoked' }
                        Mock -ModuleName $moduleName Get-ConfigValue { return $false } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'WSL' }
                        Mock -ModuleName $moduleName Get-ConfigValue { return $false } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'LinuxOnly' }
                    }

                    It 'returns all running without issues' {
                        $result = Get-RunningState -SetupType 'MultiVMK8s'
                        $result.IsRunning | Should -BeTrue
                        $result.Issues | Should -BeNullOrEmpty
                    }
                }

                Context 'Windows VM is not running' {
                    BeforeAll {
                        Mock -ModuleName $moduleName Get-IsVmRunning { return $true } -ParameterFilter { $Name -eq 'kubemaster' }
                        Mock -ModuleName $moduleName Get-VmState { return 'Running' } -ParameterFilter { $Name -eq 'kubemaster' }
                        Mock -ModuleName $moduleName Get-IsVmRunning { return $false } -ParameterFilter { $Name -eq 'winnode' }
                        Mock -ModuleName $moduleName Get-VmState { return 'stopped' } -ParameterFilter { $Name -eq 'winnode' }
                        Mock -ModuleName $moduleName Get-VmState { throw 'wrong VM name' } -ParameterFilter { $Name -ne 'kubemaster' -and $Name -ne 'winnode' }
                        Mock -ModuleName $moduleName Get-Service { throw 'must not be invoked' }
                        Mock -ModuleName $moduleName Get-ConfigValue { return $false } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'WSL' }
                        Mock -ModuleName $moduleName Get-ConfigValue { return $false } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'LinuxOnly' }
                    }

                    It 'returns not all running with VM issue' {
                        $result = Get-RunningState -SetupType 'MultiVMK8s'
                        $result.IsRunning | Should -BeFalse
                        $result.Issues.Count | Should -Be 1
                        $result.Issues[0] | Should -Match 'winnode'
                        $result.Issues[0] | Should -Match 'not running'
                        $result.Issues[0] | Should -Match 'stopped'
                        $result.Issues[0] | Should -Match 'VM'
                    }
                }

                Context 'nothing is not running' {
                    BeforeAll {
                        Mock -ModuleName $moduleName Get-IsVmRunning { return $false } -ParameterFilter { $Name -eq 'kubemaster' -or $Name -eq 'winnode' }
                        Mock -ModuleName $moduleName Get-VmState { return 'stopped' } -ParameterFilter { $Name -eq 'kubemaster' -or $Name -eq 'winnode' }
                        Mock -ModuleName $moduleName Get-VmState { throw 'wrong VM name' } -ParameterFilter { $Name -ne 'kubemaster' -and $Name -ne 'winnode' }
                        Mock -ModuleName $moduleName Get-Service { throw 'must not be invoked' }
                        Mock -ModuleName $moduleName Get-ConfigValue { return $false } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'WSL' }
                        Mock -ModuleName $moduleName Get-ConfigValue { return $false } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'LinuxOnly' }
                    }

                    It 'returns nothing running with all issues' {
                        $result = Get-RunningState -SetupType 'MultiVMK8s'
                        $result.IsRunning | Should -BeFalse
                        $result.Issues.Count | Should -Be 2
                        $result.Issues[0] | Should -Match 'kubemaster'
                        $result.Issues[0] | Should -Match 'not running'
                        $result.Issues[0] | Should -Match 'stopped'
                        $result.Issues[0] | Should -Match 'VM'
                        $result.Issues[1] | Should -Match 'winnode'
                        $result.Issues[1] | Should -Match 'not running'
                        $result.Issues[1] | Should -Match 'stopped'
                        $result.Issues[1] | Should -Match 'VM'
                    }
                }
            }

            Context 'master on WSL' {
                Context 'everything is running' {
                    BeforeAll {
                        Mock -ModuleName $moduleName Get-IsWslRunning { return $true }
                        Mock -ModuleName $moduleName Get-VmState { return 'Running' } -ParameterFilter { $Name -eq 'winnode' }
                        Mock -ModuleName $moduleName Get-VmState { throw 'wrong VM name' } -ParameterFilter { $Name -ne 'winnode' }
                        Mock -ModuleName $moduleName Get-Service { throw 'must not be invoked' }
                        Mock -ModuleName $moduleName Get-ConfigValue { return $true } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'WSL' }
                        Mock -ModuleName $moduleName Get-ConfigValue { return $false } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'LinuxOnly' }
                    }

                    It 'returns all running without issues' {
                        $result = Get-RunningState -SetupType 'MultiVMK8s'
                        $result.IsRunning | Should -BeTrue
                        $result.Issues | Should -BeNullOrEmpty
                    }
                }

                Context 'Windows VM is not running' {
                    BeforeAll {
                        Mock -ModuleName $moduleName Get-IsWslRunning { return $true }
                        Mock -ModuleName $moduleName Get-VmState { return 'stopped' } -ParameterFilter { $Name -eq 'winnode' }
                        Mock -ModuleName $moduleName Get-VmState { throw 'wrong VM name' } -ParameterFilter { $Name -ne 'winnode' }
                        Mock -ModuleName $moduleName Get-Service { throw 'must not be invoked' }
                        Mock -ModuleName $moduleName Get-ConfigValue { return $true } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'WSL' }
                        Mock -ModuleName $moduleName Get-ConfigValue { return $false } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'LinuxOnly' }
                    }

                    It 'returns not all running with VM issue' {
                        $result = Get-RunningState -SetupType 'MultiVMK8s'
                        $result.IsRunning | Should -BeFalse
                        $result.Issues.Count | Should -Be 1
                        $result.Issues[0] | Should -Match 'winnode'
                        $result.Issues[0] | Should -Match 'not running'
                        $result.Issues[0] | Should -Match 'stopped'
                        $result.Issues[0] | Should -Match 'VM'
                    }
                }

                Context 'WSL is not running' {
                    BeforeAll {
                        Mock -ModuleName $moduleName Get-IsWslRunning { return $false }
                        Mock -ModuleName $moduleName Get-VmState { return 'Running' } -ParameterFilter { $Name -eq 'winnode' }
                        Mock -ModuleName $moduleName Get-VmState { throw 'wrong VM name' } -ParameterFilter { $Name -ne 'winnode' }
                        Mock -ModuleName $moduleName Get-Service { throw 'must not be invoked' }
                        Mock -ModuleName $moduleName Get-ConfigValue { return $true } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'WSL' }
                        Mock -ModuleName $moduleName Get-ConfigValue { return $false } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'LinuxOnly' }
                    }

                    It 'returns not all running with VM issue' {
                        $result = Get-RunningState -SetupType 'MultiVMK8s'
                        $result.IsRunning | Should -BeFalse
                        $result.Issues.Count | Should -Be 1
                        $result.Issues[0] | Should -Match 'kubemaster'
                        $result.Issues[0] | Should -Match 'not running'
                        $result.Issues[0] | Should -Match 'WSL'
                    }
                }

                Context 'nothing is not running' {
                    BeforeAll {
                        Mock -ModuleName $moduleName Get-IsWslRunning { return $false }
                        Mock -ModuleName $moduleName Get-VmState { return 'stopped' } -ParameterFilter { $Name -eq 'winnode' }
                        Mock -ModuleName $moduleName Get-VmState { throw 'wrong VM name' } -ParameterFilter { $Name -ne 'winnode' }
                        Mock -ModuleName $moduleName Get-Service { throw 'must not be invoked' }
                        Mock -ModuleName $moduleName Get-ConfigValue { return $true } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'WSL' }
                        Mock -ModuleName $moduleName Get-ConfigValue { return $false } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'LinuxOnly' }
                    }

                    It 'returns nothing running with all issues' {
                        $result = Get-RunningState -SetupType 'MultiVMK8s'
                        $result.IsRunning | Should -BeFalse
                        $result.Issues.Count | Should -Be 2
                        $result.Issues[0] | Should -Match 'kubemaster'
                        $result.Issues[0] | Should -Match 'not running'
                        $result.Issues[0] | Should -Match 'WSL'
                        $result.Issues[1] | Should -Match 'winnode'
                        $result.Issues[1] | Should -Match 'not running'
                        $result.Issues[1] | Should -Match 'stopped'
                        $result.Issues[1] | Should -Match 'VM'
                    }
                }
            }
        }

        Context 'Linux-only multi-vm setup' {
            Context 'master on Linux VM' {
                Context 'everything is running' {
                    BeforeAll {
                        Mock -ModuleName $moduleName Get-IsVmRunning { return $true } -ParameterFilter { $Name -eq 'kubemaster' }
                        Mock -ModuleName $moduleName Get-VmState { return 'Running' } -ParameterFilter { $Name -eq 'kubemaster' }
                        Mock -ModuleName $moduleName Get-VmState { throw 'wrong VM name' } -ParameterFilter { $Name -ne 'kubemaster' }
                        Mock -ModuleName $moduleName Get-Service { throw 'must not be invoked' }
                        Mock -ModuleName $moduleName Get-ConfigValue { return $false } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'WSL' }
                        Mock -ModuleName $moduleName Get-ConfigValue { return $true } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'LinuxOnly' }
                    }

                    It 'returns all running without issues' {
                        $result = Get-RunningState -SetupType 'MultiVMK8s'
                        $result.IsRunning | Should -BeTrue
                        $result.Issues | Should -BeNullOrEmpty
                    }
                }

                Context 'nothing is not running' {
                    BeforeAll {
                        Mock -ModuleName $moduleName Get-IsVmRunning { return $false } -ParameterFilter { $Name -eq 'kubemaster' }
                        Mock -ModuleName $moduleName Get-VmState { return 'stopped' } -ParameterFilter { $Name -eq 'kubemaster' }
                        Mock -ModuleName $moduleName Get-VmState { throw 'wrong VM name' } -ParameterFilter { $Name -ne 'kubemaster' }
                        Mock -ModuleName $moduleName Get-Service { throw 'must not be invoked' }
                        Mock -ModuleName $moduleName Get-ConfigValue { return $false } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'WSL' }
                        Mock -ModuleName $moduleName Get-ConfigValue { return $true } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'LinuxOnly' }
                    }

                    It 'returns nothing running with all issues' {
                        $result = Get-RunningState -SetupType 'MultiVMK8s'
                        $result.IsRunning | Should -BeFalse
                        $result.Issues.Count | Should -Be 1
                        $result.Issues[0] | Should -Match 'kubemaster'
                        $result.Issues[0] | Should -Match 'not running'
                        $result.Issues[0] | Should -Match 'stopped'
                        $result.Issues[0] | Should -Match 'VM'
                    }
                }
            }

            Context 'master on WSL' {
                Context 'everything is running' {
                    BeforeAll {
                        Mock -ModuleName $moduleName Get-IsWslRunning { return $true }
                        Mock -ModuleName $moduleName Get-Service { throw 'must not be invoked' }
                        Mock -ModuleName $moduleName Get-ConfigValue { return $true } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'WSL' }
                        Mock -ModuleName $moduleName Get-ConfigValue { return $true } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'LinuxOnly' }
                    }

                    It 'returns all running without issues' {
                        $result = Get-RunningState -SetupType 'MultiVMK8s'
                        $result.IsRunning | Should -BeTrue
                        $result.Issues | Should -BeNullOrEmpty
                    }
                }

                Context 'nothing is not running' {
                    BeforeAll {
                        Mock -ModuleName $moduleName Get-IsWslRunning { return $false }
                        Mock -ModuleName $moduleName Get-Service { throw 'must not be invoked' }
                        Mock -ModuleName $moduleName Get-ConfigValue { return $true } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'WSL' }
                        Mock -ModuleName $moduleName Get-ConfigValue { return $true } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'LinuxOnly' }
                    }

                    It 'returns nothing running with all issues' {
                        $result = Get-RunningState -SetupType 'MultiVMK8s'
                        $result.IsRunning | Should -BeFalse
                        $result.Issues.Count | Should -Be 1
                        $result.Issues[0] | Should -Match 'kubemaster'
                        $result.Issues[0] | Should -Match 'not running'
                        $result.Issues[0] | Should -Match 'WSL'
                    }
                }
            }
        }
    }

    Context 'invalid setup type' {
        It 'throws' {
            { Get-RunningState -SetupType 'invalid-type' } | Should -Throw
        }
    }
}