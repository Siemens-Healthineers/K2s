# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

BeforeAll {
    $module = "$PSScriptRoot\Status.module.psm1"

    $moduleName = (Import-Module $module -PassThru -Force).Name
}

Describe 'Get-Status' -Tag 'unit' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log {}
    }
    
    Context 'progress display disabled' {
        Context 'setup type is invalid' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-SetupInfo { return @{Name = 'invalid'; ValidationError = 'invalid type' } }
            }
            
            It 'returns status with setup type info immediately without gathering additional data' {
                InModuleScope -ModuleName $moduleName {
                    $result = Get-Status
                    $result.SetupInfo.Name | Should -Be 'invalid'
                    $result.SetupInfo.ValidationError | Should -Be 'invalid type'
                    $result.SmbHostType | Should -BeNullOrEmpty
                }
            }
        }
        
        Context 'setup type is valid' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-SetupInfo { return @{Name = 'valid' } }
                Mock -ModuleName $moduleName Get-EnabledAddons { return @{Addons = 'a1', 'a2' } }
                Mock -ModuleName $moduleName Get-RunningState { return @{IsRunning = $false } }

                InModuleScope -ModuleName $moduleName {
                    $script:result = Get-Status
                }
            }
            
            It 'returns setup type' {
                InModuleScope -ModuleName $moduleName {
                    $result.SetupInfo.Name | Should -Be 'valid'
                    $result.SetupInfo.ValidationError | Should -BeNullOrEmpty
                }
            }

            It 'returns addons' {
                InModuleScope -ModuleName $moduleName {
                    $result.EnabledAddons.Count | Should -Be 2
                    $result.EnabledAddons[0] | Should -Be 'a1'
                    $result.EnabledAddons[1] | Should -Be 'a2'
                }
            }
        }
        
        Context 'cluster is not running' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-SetupInfo { return @{Name = 'valid' } }
                Mock -ModuleName $moduleName Get-EnabledAddons {}
                Mock -ModuleName $moduleName Get-RunningState { return @{IsRunning = $false } }

                InModuleScope -ModuleName $moduleName {
                    $script:result = Get-Status
                }
            }

            It 'returns status immediately without gathering additional data' {
                InModuleScope -ModuleName $moduleName {
                    $result.RunningState.IsRunning | Should -BeFalse
                }
            }
        }
        
        Context 'cluster is running' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-SetupInfo { return @{Name = 'valid' } }
                Mock -ModuleName $moduleName Get-EnabledAddons {}
                Mock -ModuleName $moduleName Get-RunningState { return @{IsRunning = $true } }
                Mock -ModuleName $moduleName Get-Nodes { return @{Name = 'n1' }, @{Name = 'n2' } }
                Mock -ModuleName $moduleName Get-SystemPods { return @{Name = 'p1' }, @{Name = 'p2' } }
                Mock -ModuleName $moduleName Get-K8sVersionInfo { return @{K8sServerVersion = '123'; K8sClientVersion = '321' } }

                InModuleScope -ModuleName $moduleName {
                    $script:result = Get-Status
                }
            }

            It 'returns is running state' {
                InModuleScope -ModuleName $moduleName {
                    $result.RunningState.IsRunning | Should -BeTrue
                }
            }

            It 'returns K8s version info' {
                InModuleScope -ModuleName $moduleName {
                    $result.K8sVersionInfo.K8sClientVersion | Should -Be '321'
                    $result.K8sVersionInfo.K8sServerVersion | Should -Be '123'
                }
            }
            
            It 'returns nodes' {
                InModuleScope -ModuleName $moduleName {
                    $result.Nodes.Count | Should -Be 2
                    $result.Nodes[0].Name | Should -Be 'n1'
                    $result.Nodes[1].Name | Should -Be 'n2'
                }
            }
            
            It 'returns system pods' {
                InModuleScope -ModuleName $moduleName {
                    $result.Pods.Count | Should -Be 2
                    $result.Pods[0].Name | Should -Be 'p1'
                    $result.Pods[1].Name | Should -Be 'p2'
                }
            }
        }
    }

    Context 'progress display enabled' {
        Context 'setup type is invalid' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-SetupInfo { return @{Name = 'invalid'; ValidationError = 'invalid type' } }
                Mock -ModuleName $moduleName Write-Progress {}

                InModuleScope -ModuleName $moduleName {
                    Get-Status -ShowProgress $true
                }
            }
            
            It 'displays initial progress info' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Write-Progress -Times 1 -ParameterFilter { $Id -eq 1 -and $Status -eq '0/5' } -Scope Context
                }
            }

            It 'completes progress immediately' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Write-Progress -Times 1 -ParameterFilter { $Id -eq 1 -and $Completed -eq $true } -Scope Context
                    Should -Invoke Write-Progress -Times 2 -Scope Context
                }
            }
        }
       
        Context 'cluster is not running' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-SetupInfo { return @{Name = 'valid' } }
                Mock -ModuleName $moduleName Write-Progress {}
                Mock -ModuleName $moduleName Get-EnabledAddons {}
                Mock -ModuleName $moduleName Get-RunningState { return @{IsRunning = $false } }

                InModuleScope -ModuleName $moduleName {
                    Get-Status -ShowProgress $true
                }
            }
            
            It 'displays progress until cluster running state' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Write-Progress -Times 1 -ParameterFilter { $Id -eq 1 -and $Status -eq '0/5' } -Scope Context
                    Should -Invoke Write-Progress -Times 1 -ParameterFilter { $Id -eq 1 -and $Status -eq '1/5' } -Scope Context
                    Should -Invoke Write-Progress -Times 1 -ParameterFilter { $Id -eq 1 -and $Status -eq '2/5' } -Scope Context
                }
            }

            It 'completes progress immediately after running state' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Write-Progress -Times 1 -ParameterFilter { $Id -eq 1 -and $Completed -eq $true } -Scope Context
                    Should -Invoke Write-Progress -Times 4 -Scope Context
                }
            }
        }
        
        Context 'cluster is running' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-SetupInfo { return @{Name = 'valid' } }
                Mock -ModuleName $moduleName Write-Progress {}
                Mock -ModuleName $moduleName Get-EnabledAddons {}
                Mock -ModuleName $moduleName Get-RunningState { return @{IsRunning = $true } }
                Mock -ModuleName $moduleName Get-Nodes {}
                Mock -ModuleName $moduleName Get-SystemPods {}
                Mock -ModuleName $moduleName Get-K8sVersionInfo {}

                InModuleScope -ModuleName $moduleName {
                    Get-Status -ShowProgress $true
                }
            }
            
            It 'displays progress until completion' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Write-Progress -Times 1 -ParameterFilter { $Id -eq 1 -and $Status -eq '0/5' } -Scope Context
                    Should -Invoke Write-Progress -Times 1 -ParameterFilter { $Id -eq 1 -and $Status -eq '1/5' } -Scope Context
                    Should -Invoke Write-Progress -Times 1 -ParameterFilter { $Id -eq 1 -and $Status -eq '2/5' } -Scope Context
                    Should -Invoke Write-Progress -Times 1 -ParameterFilter { $Id -eq 1 -and $Status -eq '3/5' } -Scope Context
                    Should -Invoke Write-Progress -Times 1 -ParameterFilter { $Id -eq 1 -and $Status -eq '4/5' } -Scope Context
                    Should -Invoke Write-Progress -Times 1 -ParameterFilter { $Id -eq 1 -and $Status -eq '5/5' } -Scope Context
                    Should -Invoke Write-Progress -Times 1 -ParameterFilter { $Id -eq 1 -and $Status -eq '5/5' -and $PercentComplete -eq 100 } -Scope Context
                    Should -Invoke Write-Progress -Times 8 -Scope Context
                }
            }
        }
    }
}