# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
    $moduleName = (Import-Module "$PSScriptRoot\addons.module.psm1" -PassThru -Force).Name
}

Describe 'Find-AddonManifests' -Tag 'unit', 'ci', 'addon' {
    Context 'Directory not specified' {
        It 'throws' {
            { Find-AddonManifests } | Should -Throw -ExpectedMessage 'Directory not specified'
        }
    }

    Context 'Directory specified' {
        BeforeAll {
            $foundFiles = @{FullName = 'f1' }, @{FullName = 'f2' }, @{FullName = 'f3' }

            Mock -ModuleName $moduleName Get-ChildItem { return $foundFiles }
        }

        It 'starts the search' {
            InModuleScope $moduleName {
                $result = Find-AddonManifests -Directory 'test'

                Should -Invoke Get-ChildItem -Times 1 -Scope Context -ParameterFilter { $Path -eq 'test' -and $Filter -eq 'addon.manifest.yaml' }

                $result[0] | Should -Be 'f1'
                $result[1] | Should -Be 'f2'
                $result[2] | Should -Be 'f3'
            }
        }
    }
}

Describe 'Get-EnabledAddons' -Tag 'unit', 'ci', 'addon' {
    Context 'all addons disabled' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Get-AddonsConfig { return $null }
        }

        It 'returns object with null array' {
            InModuleScope $moduleName {
                $result = Get-EnabledAddons

                $result | Should -BeNullOrEmpty
            }
        }
    }

    Context 'some addons enabled' {
        BeforeAll {
            $addonsConfig = @{Name = 'a1'; Implementation = @("i1") }, @{Name = 'a2' }

            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Get-AddonsConfig { return $addonsConfig }
        }

        It 'returns enabled addons' {
            InModuleScope $moduleName {
                $result = Get-EnabledAddons

                $result.Count | Should -Be 2
                $result[0].Name | Should -Be 'a1'
                $result[0].Implementations[0] | Should -Be 'i1'
                $result[1].Name | Should -Be 'a2'
            }
        }
    }
}

Describe 'ConvertTo-NewConfigStructure' -Tag 'unit', 'ci', 'addon' {
    Context 'config structure needs to be migrated from <= v0.5 to current version' {
        BeforeAll {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
            $oldConfig = ConvertFrom-Json '[ "gateway-nginx", "metrics-server", "dashboard", "ingress-nginx", "traefik" ]'

            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
            $expectedResult = [pscustomobject]@{Name = 'gateway-api' }, [pscustomobject]@{Name = 'metrics' }, [pscustomobject]@{Name = 'dashboard' }, [pscustomobject]@{Name = 'ingress'; Implementation = @("nginx")}, [pscustomobject]@{Name = 'ingress'; Implementation = @("traefik")}
        }

        BeforeEach {
            $log = [System.Collections.ArrayList]@()
            Mock -ModuleName $moduleName Write-Information { $log.Add($MessageData) | Out-Null }
        }

        It 'migrates the structure correctly' {
            InModuleScope -ModuleName $moduleName -Parameters @{oldConfig = $oldConfig; expectedResult = $expectedResult } {
                ConvertTo-NewConfigStructure -Config $oldConfig | ConvertTo-Json | Should -Be $($expectedResult | ConvertTo-Json)
            }
        }

        It 'logs the migration for each addon' {
            InModuleScope -ModuleName $moduleName -Parameters @{oldConfig = $oldConfig; log = $log } {
                ConvertTo-NewConfigStructure -Config $oldConfig

                $log.Count | Should -Be 5
                $log[0] | Should -Be "Config for addon 'gateway-nginx' migrated."
                $log[1] | Should -Be "Config for addon 'metrics-server' migrated."
                $log[2] | Should -Be "Config for addon 'dashboard' migrated."
                $log[3] | Should -Be "Config for addon 'ingress-nginx' migrated."
                $log[4] | Should -Be "Config for addon 'traefik' migrated."
            }
        }
    }

    Context 'config structure needs to be migrated from v0.5 < version <= v1.1.1 to current version' {
        BeforeAll {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
            $oldConfig = [pscustomobject]@{Name = 'gateway-nginx' }, [pscustomobject]@{Name = 'metrics-server' }, [pscustomobject]@{Name = 'dashboard' }, [pscustomobject]@{Name = 'ingress-nginx'}, [pscustomobject]@{Name = 'traefik'}, [pscustomobject]@{Name = 'smb-share'; SmbHostType = 'linux' } 

            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
            $expectedResult = [pscustomobject]@{Name = 'gateway-api' }, [pscustomobject]@{Name = 'metrics' }, [pscustomobject]@{Name = 'dashboard' }, [pscustomobject]@{Name = 'ingress'; Implementation = "nginx"}, [pscustomobject]@{Name = 'ingress'; Implementation = "traefik"}, [pscustomobject]@{Name = 'storage'; SmbHostType = 'linux' } 
        }

        BeforeEach {
            $log = [System.Collections.ArrayList]@()
            Mock -ModuleName $moduleName Write-Information { $log.Add($MessageData) | Out-Null }
        }
    
        It 'migrates the structure correctly' {
            InModuleScope -ModuleName $moduleName -Parameters @{oldConfig = $oldConfig; expectedResult = $expectedResult } {
                ConvertTo-NewConfigStructure -Config $oldConfig | ConvertTo-Json | Should -Be $($expectedResult | ConvertTo-Json)
            }
        }

        It 'logs the migration for each addon' {
            InModuleScope -ModuleName $moduleName -Parameters @{oldConfig = $oldConfig; log = $log } {
                ConvertTo-NewConfigStructure -Config $oldConfig

                $log.Count | Should -Be 5
                $log[0] | Should -Be "Config for addon 'gateway-nginx' migrated."
                $log[1] | Should -Be "Config for addon 'metrics-server' migrated."
                $log[2] | Should -Be "Config for addon 'ingress-nginx' migrated."
                $log[3] | Should -Be "Config for addon 'traefik' migrated."
                $log[4] | Should -Be "Config for addon 'smb-share' migrated."
            }
        }
    }

    Context 'config structure contains unexpected addon types' {
        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { ConvertTo-NewConfigStructure -Config (332, 213, 444) } | Should -Throw -ExpectedMessage "Unexpected addon config type 'Int32'"
            }
        }
    }
}

Describe 'Test-IsAddonEnabled' -Tag 'unit', 'ci', 'addon' {
    Context 'no addon name specified' {
        It 'throws' {
            { Test-IsAddonEnabled } | Should -Throw
        }
    }

    Context 'addon disabled' {
        BeforeAll {
            $enabledAddons = @{ Name = 'a2' }, @{ Name = 'a3' }

            Mock -ModuleName $moduleName Get-AddonsConfig { return $enabledAddons }
        }

        It 'returns false' {
            Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'a1' }) | Should -BeFalse
        }

        Context 'implementation disabled' {
            BeforeAll {
                $enabledAddons = @{ Name = 'a2'; Implementation = @('i1') }, @{ Name = 'a3' }
    
                Mock -ModuleName $moduleName Get-AddonsConfig { return $enabledAddons }
            }
    
            It 'returns false' {
                Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'a2'; Implementation = 'i2' }) | Should -BeFalse
            }
        }
    }

    Context 'addon enabled' {
        BeforeAll {
            $enabledAddons = @{ Name = 'a1' }, @{ Name = 'a2' }

            Mock -ModuleName $moduleName Get-AddonsConfig { return $enabledAddons }
        }

        It 'returns true' {
            Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'a1' }) | Should -BeTrue
        }

        Context 'implementation enabled' {
            BeforeAll {
                $enabledAddons = @{ Name = 'a1'; Implementation = @('i1') }, @{ Name = 'a2' }
    
                Mock -ModuleName $moduleName Get-AddonsConfig { return $enabledAddons }
            }
    
            It 'returns true' {
                Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'a1'; Implementation = 'i1'  }) | Should -BeTrue
            }
        }
    }
}

Describe 'Invoke-AddonsHooks' -Tag 'unit', 'ci', 'addon' {
    Context 'no hook type specified' {
        It 'throws' {
            { Invoke-AddonsHooks } | Should -Throw
        }
    }

    Context 'invalid hook type specified' {
        It 'throws' {
            { Invoke-AddonsHooks -HookType 'invalid' } | Should -Throw
        }
    }

    Context 'hooks dir not existing' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $Path -match 'hooks' }
            Mock -ModuleName $moduleName Test-Path { throw 'unexpected' } -ParameterFilter { $Path -notmatch 'hooks' }
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Get-ChildItem { }
            Mock -ModuleName $moduleName Invoke-Script { }
        }

        It 'skips the invocation' {
            Invoke-AddonsHooks -HookType 'AfterStart'

            InModuleScope -ModuleName $moduleName {
                Should -Invoke Get-ChildItem -Times 0 -Scope Context
                #TODO : Check mock of Write-Log
                #Should -Invoke Write-Log -Times 1 -ParameterFilter { $InputObject -match 'skipping' } -Scope Context
                Should -Invoke Invoke-Script -Times 0 -Scope Context
            }
        }
    }

    Context 'valid hook type specified' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -match 'hooks' }
            Mock -ModuleName $moduleName Test-Path { throw 'unexpected' } -ParameterFilter { $Path -notmatch 'hooks' }
            Mock -ModuleName $moduleName Get-ChildItem { return @{FullName = 'do-something-useful.AfterStart.ps1' } }
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Invoke-Script { }
        }

        It 'executes all matching scripts in hooks directory' {
            Invoke-AddonsHooks -HookType 'AfterStart'

            InModuleScope -ModuleName $moduleName {
                Should -Invoke Get-ChildItem -Times 1 -ParameterFilter { $Path -match 'hooks' -and $Filter -eq '*.AfterStart.ps1' } -Scope Context
                Should -Invoke Write-Log -Times 1
                Should -Invoke Invoke-Script -Times 1 -ParameterFilter { $FilePath -eq 'do-something-useful.AfterStart.ps1' } -Scope Context
            }
        }
    }
}

Describe 'Copy-ScriptsToHooksDir' -Tag 'unit', 'ci', 'addon' {
    Context 'script files not specified' {
        It 'throws' {
            { Copy-ScriptsToHooksDir } | Should -Throw -ExpectedMessage 'No script file paths specified'
        }
    }

    Context 'hooks dir not existing' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $Path -match 'hooks' }
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName New-Item {}
            Mock -ModuleName $moduleName Get-FileName {}
            Mock -ModuleName $moduleName Copy-Item {}

            Copy-ScriptsToHooksDir -ScriptPaths $null
        }

        It 'creates the hooks dir' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke New-Item -Times 1 -Scope Context -ParameterFilter { $Path -match 'hooks' -and $ItemType -eq 'Directory' }
            }
        }
    }

    Context 'some hook scripts do not exist' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -match 'hooks' }
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -eq 's1' -or $Path -eq 's3' }
            Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $Path -eq 's2' -or $Path -eq 's4' }
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Write-Warning {}
            Mock -ModuleName $moduleName Get-FileName {}
            Mock -ModuleName $moduleName Get-FileName { return 's1' } -ParameterFilter { $FilePath -eq 's1' }
            Mock -ModuleName $moduleName Get-FileName { return 's3' } -ParameterFilter { $FilePath -eq 's3' }
            Mock -ModuleName $moduleName Copy-Item {}

            Copy-ScriptsToHooksDir -ScriptPaths 's1', 's2', 's3', 's4'
        }

        It 'skips the copying of non-existent hooks' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Get-FileName -Times 0 -ParameterFilter { $FilePath -eq 's2' -or $FilePath -eq 's4' } -Scope Context
            }
        }

        It 'informs the user about non-existent hooks' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -match "Cannot copy addon hook 's2'" } -Scope Context
                Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -match "Cannot copy addon hook 's4'" } -Scope Context
            }
        }

        It 'copies the existent hooks' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Copy-Item -Times 1 -ParameterFilter { $Path -eq 's1' -and $Destination -match 'hooks\\s1' } -Scope Context
                Should -Invoke Copy-Item -Times 1 -ParameterFilter { $Path -eq 's3' -and $Destination -match 'hooks\\s3' } -Scope Context
            }
        }
    }
}

Describe 'Remove-ScriptsFromHooksDir' -Tag 'unit', 'ci', 'addon' {
    Context 'scripts not specified' {
        It 'throws' {
            { Remove-ScriptsFromHooksDir } | Should -Throw -ExpectedMessage 'No script file names specified'
        }
    }

    Context 'hooks dir not existing' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $Path -match 'hooks' }
            Mock -ModuleName $moduleName Write-Log {}

            Remove-ScriptsFromHooksDir -ScriptNames 's1', 's2'
        }

        It 'skips the removal' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Log -Times 1 -Scope Context
            }
        }

        It 'informs the user' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Log -Times 1 -Scope Context -ParameterFilter { $Messages -match 'nothing to remove' }
            }
        }
    }

    Context 'some hooks do not exist' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -match 'hooks' }
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -match 'hooks\\s1' -or $Path -match 'hooks\\s3' }
            Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $Path -match 'hooks\\s2' -or $Path -match 'hooks\\s4' }
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Write-Warning {}
            Mock -ModuleName $moduleName Remove-Item {}

            Remove-ScriptsFromHooksDir -ScriptNames 's1', 's2', 's3', 's4'
        }

        It 'skips the removal of non-existent hooks' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Remove-Item -Times 0 -ParameterFilter { $Path -match 'hooks\\s2' -or $Path -match 'hooks\\s4' } -Scope Context
            }
        }

        It 'informs the user about non-existent hooks' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -match 'Cannot remove addon hook' -and $Message -match 'hooks\\s2' } -Scope Context
                Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -match 'Cannot remove addon hook' -and $Message -match 'hooks\\s4' } -Scope Context
            }
        }

        It 'removes the existent hooks' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Remove-Item -Times 1 -ParameterFilter { $Path -match 'hooks\\s1' } -Scope Context
                Should -Invoke Remove-Item -Times 1 -ParameterFilter { $Path -match 'hooks\\s3' } -Scope Context
            }
        }
    }

    Context 'all hooks existent' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -match 'hooks' -or $Path -match 'hooks\\s' }
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Write-Warning { throw 'unexpected' }
            Mock -ModuleName $moduleName Remove-Item {}

            Remove-ScriptsFromHooksDir -ScriptNames 's1', 's2', 's3', 's4'
        }

        It 'removes all hooks' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Remove-Item -Times 1 -ParameterFilter { $Path -match 'hooks\\s1' } -Scope Context
                Should -Invoke Remove-Item -Times 1 -ParameterFilter { $Path -match 'hooks\\s2' } -Scope Context
                Should -Invoke Remove-Item -Times 1 -ParameterFilter { $Path -match 'hooks\\s3' } -Scope Context
                Should -Invoke Remove-Item -Times 1 -ParameterFilter { $Path -match 'hooks\\s4' } -Scope Context
            }
        }
    }
}

Describe 'Get-AddonConfig' -Tag 'unit', 'ci', 'addon' {
    Context 'addon name not specified' {
        It 'throws' {
            { Get-AddonConfig } | Should -Throw -ExpectedMessage 'Name not specified'
        }
    }

    Context 'no addons configured' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-AddonsConfig { return $null }
        }

        It 'returns nothing' {
            Get-AddonConfig -Name 'my-addon' | Should -BeNullOrEmpty
        }
    }

    Context 'addon name not among configured addons' {
        BeforeAll {
            $config = [pscustomobject]@{Name = 'a1' }, [pscustomobject]@{Name = 'a2' }

            Mock -ModuleName $moduleName Get-AddonsConfig { return $config }
        }

        It 'returns nothing' {
            Get-AddonConfig -Name 'a3' | Should -BeNullOrEmpty
        }
    }

    Context 'addon name among configured addons' {
        BeforeAll {
            $expectedAddon = [pscustomobject]@{Name = 'a2' }
            $config = [pscustomobject]@{Name = 'a1' }, $expectedAddon

            Mock -ModuleName $moduleName Get-AddonsConfig { return $config }
        }

        It 'returns addon' {
            Get-AddonConfig -Name 'a2' | Should -Be $expectedAddon
        }
    }
}

Describe 'Backup-Addons' -Tag 'unit', 'ci', 'addon' {
    Context 'no addons config existing' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Get-AddonsConfig { return $null }
            Mock -ModuleName $moduleName Test-Path { }

            InModuleScope -ModuleName $moduleName {
                Backup-Addons -BackupDir 'test'
            }
        }

        It 'skips the backup' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Test-Path -Times 0 -Scope Context
            }
        }

        It 'informs the user' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Log -Times 1 -Scope Context -ParameterFilter { $Messages -match 'skipping' }
            }
        }
    }

    Context 'backup dir not existing' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Get-AddonsConfig { return '' }
            Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $Path -eq 'test' }
            Mock -ModuleName $moduleName New-Item {  }
            Mock -ModuleName $moduleName ConvertTo-NewConfigStructure {  }
            Mock -ModuleName $moduleName Join-Path { return 'test' }
            Mock -ModuleName $moduleName ConvertTo-Json { }
            Mock -ModuleName $moduleName Set-Content {  }
            Mock -ModuleName $moduleName Invoke-BackupRestoreHooks {  }

            InModuleScope -ModuleName $moduleName {
                Backup-Addons -BackupDir 'test'
            }
        }

        It 'creates the backup dir ' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke New-Item -Times 1 -Scope Context -ParameterFilter { $Path -eq 'test' -and $ItemType -eq 'Directory' }
            }
        }

        It 'informs the user' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Log -Times 1 -Scope Context -ParameterFilter { $Messages -match 'backup dir not existing' }
            }
        }
    }

    Context 'addons config existing' {
        BeforeAll {
            $log = [System.Collections.ArrayList]@()

            Mock -ModuleName $moduleName Write-Log { $log.Add($Messages) | Out-Null }
            Mock -ModuleName $moduleName Get-AddonsConfig { return 'config' }
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -eq 'dir' }
            Mock -ModuleName $moduleName ConvertTo-NewConfigStructure { Write-Information 'log-from-migration'
                return 'migrated'
            }
            Mock -ModuleName $moduleName Join-Path { return 'path' } -ParameterFilter { $Path[0] -eq 'dir' -and $Path[1] -eq $backupFileName }
            Mock -ModuleName $moduleName ConvertTo-Json { return 'json' } -ParameterFilter { $InputObject.Config -eq 'migrated' }
            Mock -ModuleName $moduleName Set-Content {  }
            Mock -ModuleName $moduleName Invoke-BackupRestoreHooks {  }
            Mock -ModuleName $moduleName Write-Warning { }

            InModuleScope -ModuleName $moduleName {
                Backup-Addons -BackupDir 'dir'
            }
        }

        It 'migrates the config structure' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke ConvertTo-NewConfigStructure -Times 1 -Scope Context -ParameterFilter { $Config -eq 'config' }
            }
        }

        It 'migration informs the user' {
            InModuleScope -ModuleName $moduleName -Parameters @{log = $log } {
                $log.Count | Should -BeGreaterOrEqual 2
                $log[1] | Should -Be 'log-from-migration'
            }
        }

        It 'saves the config structure to config file' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Set-Content -Times 1 -Scope Context -ParameterFilter { $Value -eq 'json' -and $Path -eq 'path' }
            }
        }

        It 'invokes backup hooks' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Invoke-BackupRestoreHooks -Times 1 -Scope Context -ParameterFilter { $HookType -eq 'Backup' -and $BackupDir -eq 'dir' }
            }
        }
    }

    Context 'addon hooks exist for backup and restore' {
        BeforeAll {
            $warnings = [System.Collections.ArrayList]@()

            Mock -ModuleName $moduleName Write-Log {  }
            Mock -ModuleName $moduleName Write-Warning { $warnings.Add($Message) | Out-Null }
            Mock -ModuleName $moduleName Get-AddonsConfig {
                return @(
                    [pscustomobject]@{ Name = 'Addon1' },
                    [pscustomobject]@{ Name = $null }
                )
            }
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -eq 'dir' }
            Mock -ModuleName $moduleName ConvertTo-NewConfigStructure { Write-Information 'log-from-migration'
                return @(
                    [pscustomobject]@{ Name = 'Addon1' },
                    [pscustomobject]@{ Name = $null }
                )
            }
            Mock -ModuleName $moduleName Join-Path { return 'path' } -ParameterFilter { $Path[0] -eq 'dir' -and $Path[1] -eq $backupFileName }
            Mock -ModuleName $moduleName ConvertTo-Json { return 'json' } -ParameterFilter { $InputObject.Config -eq @(
                [pscustomobject]@{ Name = 'Addon1' },
                [pscustomobject]@{ Name = $null }
            ) }
            Mock -ModuleName $moduleName Set-Content {  }
            Mock -ModuleName $moduleName Get-ScriptRoot { return 'C:\Scripts' }
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -eq 'C:\Scripts\Addon1\hooks' }
            Mock -ModuleName $moduleName Get-ChildItem {
                return @(
                    [pscustomobject]@{ FullName = 'C:\Scripts\Addon1\hooks\Backup.ps1'; Name = 'Backup.ps1' },
                    [pscustomobject]@{ FullName = 'C:\Scripts\Addon1\hooks\Restore.ps1'; Name = 'Restore.ps1' },
                    [pscustomobject]@{ FullName = 'C:\Scripts\Addon1\hooks\Other.ps1'; Name = 'Other.ps1' }
                )
            }
            Mock -ModuleName $moduleName Copy-ScriptsToHooksDir { }
            Mock -ModuleName $moduleName Invoke-BackupRestoreHooks {  }

            InModuleScope -ModuleName $moduleName {
                Backup-Addons -BackupDir 'dir'
            }
        }

        It 'copies only backup and restore scripts' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Copy-ScriptsToHooksDir -Times 1 -Scope Context -ParameterFilter {
                    $ScriptPaths -contains 'C:\Scripts\Addon1\hooks\Backup.ps1' -and
                    $ScriptPaths -contains 'C:\Scripts\Addon1\hooks\Restore.ps1' -and
                    -not ($ScriptPaths -contains 'C:\Scripts\Addon1\hooks\Other.ps1')
                }
            }
        }

        It 'logs a warning for addons without a name' {
            InModuleScope -ModuleName $moduleName -Parameters @{warnings = $warnings } {
                # Write-Host "Warning messages captured during the test:"
                # $warnings | ForEach-Object { Write-Host $_ }

                $warnings[0] | Should -Be "Invalid addon config '@{Name=}' found, skipping it."
            }
        }

        It 'invokes backup hooks' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Invoke-BackupRestoreHooks -Times 1 -Scope Context -ParameterFilter { $HookType -eq 'Backup' -and $BackupDir -eq 'dir' }
            }
        }
    }
}

Describe 'Restore-Addons' -Tag 'unit', 'ci', 'addon' {
    Context 'no addons backup existing' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Join-Path { return 'path' } -ParameterFilter { $Path[0] -eq 'dir' -and $Path[1] -eq $backupFileName }
            Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $Path -eq 'path' }
            Mock -ModuleName $moduleName Get-Content { }

            InModuleScope -ModuleName $moduleName {
                Restore-Addons -BackupDir 'dir'
            }
        }

        It 'skips the restore' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Get-Content -Times 0 -Scope Context
            }
        }

        It 'informs the user' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Log -Times 1 -Scope Context -ParameterFilter { $Messages -match 'skipping' }
            }
        }
    }

    Context 'addons backup existing' {
        BeforeAll {
            $backupContentRoot = [pscustomobject]@{Config = 'a1', 'a2', 'a3' }

            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Join-Path { return 'path' } -ParameterFilter { $Path[0] -eq 'dir' -and $Path[1] -eq $backupFileName }
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -eq 'path' }
            Mock -ModuleName $moduleName Get-Content { return 'content' } -ParameterFilter { $Path -eq 'path' }
            Mock -ModuleName $moduleName ConvertFrom-Json { return $backupContentRoot } -ParameterFilter { $InputObject -eq 'content' }
            Mock -ModuleName $moduleName Enable-AddonFromConfig {  }
            Mock -ModuleName $moduleName Invoke-BackupRestoreHooks {  }

            InModuleScope -ModuleName $moduleName {
                Restore-Addons -BackupDir 'dir'
            }
        }

        It 'enables all addons from config backup' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Enable-AddonFromConfig -Times 1 -Scope Context -ParameterFilter { $Config -eq 'a1' }
                Should -Invoke Enable-AddonFromConfig -Times 1 -Scope Context -ParameterFilter { $Config -eq 'a2' }
                Should -Invoke Enable-AddonFromConfig -Times 1 -Scope Context -ParameterFilter { $Config -eq 'a3' }
            }
        }

        It 'invokes restore hooks' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Invoke-BackupRestoreHooks -Times 1 -Scope Context -ParameterFilter { $HookType -eq 'Restore' -and $BackupDir -eq 'dir' }
            }
        }
    }
}

Describe 'Invoke-BackupRestoreHooks' -Tag 'unit', 'ci', 'addon' {
    Context 'hook type not specified' {
        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Invoke-BackupRestoreHooks -BackupDir 'dir' } | Should -Throw -ExpectedMessage 'Hook type not specified'
            }
        }
    }

    Context 'hook type invalid' {
        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Invoke-BackupRestoreHooks -HookType 'invalid' -BackupDir 'dir' } | Should -Throw
            }
        }
    }

    Context 'backup dir not specified' {
        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Invoke-BackupRestoreHooks -HookType 'Backup' } | Should -Throw -ExpectedMessage 'Back-up directory not specified'
            }
        }
    }

    Context 'hooks directory not existing' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $Path -match 'hooks' }
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Get-ChildItem {}
        }

        It 'skips the invokation' {
            InModuleScope -ModuleName $moduleName {
                Invoke-BackupRestoreHooks -HookType 'Backup' -BackupDir 'backupDir'

                Should -Invoke Get-ChildItem -Times 0 -Scope Context
            }
        }
    }

    Context 'hooks non-existent' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -match 'hooks' }
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Get-ChildItem { } -ParameterFilter { $Path -match 'hooks' -and $Filter -eq '*.Backup.ps1' }
            Mock -ModuleName $moduleName Get-ChildItem { throw 'unexpected' } -ParameterFilter { $Path -notmatch 'hooks' -or $Filter -ne '*.Backup.ps1' }
        }

        It 'states that no hooks has been found' {
            InModuleScope -ModuleName $moduleName {
                Invoke-BackupRestoreHooks -HookType 'Backup' -BackupDir 'backupDir'

                Should -Invoke Write-Log -Times 1 -ParameterFilter { $Messages -match 'No back-up/restore hooks found' } -Scope Context
            }
        }
    }

    Context 'hooks existing' {
        BeforeAll {
            $scriptContent = @'
            param (
                [Parameter(Mandatory = $false)]
                [string]$BackupDir = $(throw 'Missing dir param')
            )
            if ($BackupDir -ne 'backupDir') {
                throw "'$BackupDir' not equals 'backupDir'"
            }
            return
'@
            $script1 = 'TestDrive:\s1.ps1'
            $script2 = 'TestDrive:\s2.ps1'
            Set-Content $script1 -value $scriptContent
            Set-Content $script2 -value $scriptContent

            $scripts = [pscustomobject]@{FullName = $script1 }, [pscustomobject]@{FullName = $script2 }

            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -match 'hooks' }
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Get-ChildItem { return $scripts } -ParameterFilter { $Path -match 'hooks' -and $Filter -eq '*.Backup.ps1' }
        }

        It 'executes the hooks without errors' {
            InModuleScope -ModuleName $moduleName {
                Invoke-BackupRestoreHooks -HookType 'Backup' -BackupDir 'backupDir'
            }
        }

        It 'does not state that no hooks has been found' {
            InModuleScope -ModuleName $moduleName {
                Invoke-BackupRestoreHooks -HookType 'Backup' -BackupDir 'backupDir'

                Should -Invoke Write-Log -Times 0 -ParameterFilter { $Messages -match 'No back-up/restore hooks found' } -Scope Context
            }
        }
    }
}

Describe 'Enable-AddonFromConfig' -Tag 'unit', 'ci', 'addon' {
    Context 'config object not specified' {
        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Enable-AddonFromConfig } | Should -Throw -ExpectedMessage 'Config object not specified'
            }
        }
    }

    Context "'Name' property missing on config object" {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path {}
            Mock -ModuleName $moduleName Write-Warning {}
            Mock -ModuleName $moduleName Write-Log { }

            InModuleScope -ModuleName $moduleName {
                $config = [pscustomobject] @{ SomeProp = 123 }

                Enable-AddonFromConfig -Config $config
            }
        }

        It 'skips the addon enabling' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Test-Path -Times 0 -Scope Context
            }
        }

        It 'informs the user' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Warning -Times 1 -Scope Context -ParameterFilter { $Message -match 'Invalid' -and $Message -match 'skipping' }
            }
        }
    }

    Context 'addon is obsolete after upgrade' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $Path -match '\\a1\\Enable.ps1' }
            Mock -ModuleName $moduleName Write-Warning {}
            Mock -ModuleName $moduleName Write-Log {}

            InModuleScope -ModuleName $moduleName {
                $config = [pscustomobject] @{ Name = 'a1' }

                Enable-AddonFromConfig -Config $config
            }
        }

        It 'skips the addon enabling' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Log -Times 0 -Scope Context
            }
        }

        It 'informs the user' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Warning -Times 1 -Scope Context -ParameterFilter { $Message -match 'a1' -and $Message -match 'deprecated' }
            }
        }
    }

    Context 'addon config is valid and addon existent' {
        BeforeAll {
            $scriptContent = @'
            Param (
                [parameter(Mandatory = $false)]
                [pscustomobject] $Config
            )
            if ($Config.Name -ne 'a1') {
                throw "'$($Config.Name)' not equals 'a1'"
            }
            return
'@
            $scriptPath = 'TestDrive:\a1\Enable.ps1'
            New-Item -Path 'TestDrive:\a1\' -ItemType Directory -Force
            Set-Content $scriptPath -value $scriptContent

            Mock -ModuleName $moduleName Write-Warning {}
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Get-ScriptRoot { return 'TestDrive:' }
        }

        It 'enables the addon' {
            InModuleScope -ModuleName $moduleName {
                $config = [pscustomobject] @{ Name = 'a1' }

                Enable-AddonFromConfig -Config $config

                Should -Invoke Write-Warning -Times 0 -Scope Context
            }
        }
    }
}

Describe 'Get-AddonsConfig' -Tag 'unit', 'ci', 'addon' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log { }
        Mock -ModuleName $moduleName Get-SetupConfigFilePath { return 'config-path' }
        Mock -ModuleName $moduleName Get-ConfigValue { return 'config' } -ParameterFilter { $Path -eq 'config-path' -and $Key -eq 'EnabledAddons' }
    }

    It 'calls underlying config function correctly' {
        InModuleScope -ModuleName $moduleName {
            Get-AddonsConfig | Should -Be 'config'
        }
    }
}

Describe 'Get-AddonStatus' -Tag 'unit', 'ci', 'addon' {
    Context 'Name not specified' {
        It 'throws' {
            { Get-AddonStatus -Directory 'test-dir' } | Should -Throw -ExpectedMessage 'Name not specified'
        }
    }

    Context 'Directory not specified' {
        It 'throws' {
            { Get-AddonStatus -Name 'test-name' } | Should -Throw -ExpectedMessage 'Directory not specified'
        }
    }

    Context 'addon not existing' {
        BeforeAll {
            $addonDirectory = 'test-addon-dir'
            Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $Path -match "\\$addonDirectory" }
        }

        It 'returns addon-not-found error' {
            InModuleScope -ModuleName $moduleName -Parameters @{addonDirectory = $addonDirectory } {
                $result = Get-AddonStatus -Name 'some-name' -Directory $addonDirectory

                $result.Error.Code | Should -Be (Get-ErrCodeAddonNotFound)
                $result.Error.Severity | Should -Be Warning
                $result.Error.Message | Should -Match 'not found in directory'
            }
        }
    }

    Context 'addon does not provide a status script' {
        BeforeAll {
            $addonDirectory = 'test-addon-dir'
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -eq $addonDirectory }
            Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $Path -match "$addonDirectory\\Get-Status.ps1" }
        }

        It 'returns no-addon-status error' {
            InModuleScope -ModuleName $moduleName -Parameters @{addonDirectory = $addonDirectory } {
                $result = Get-AddonStatus -Name 'some-name' -Directory $addonDirectory

                $result.Error.Code | Should -Be 'no-addon-status'
                $result.Error.Severity | Should -Be Warning
                $result.Error.Message | Should -Match 'does not provide detailed status information'
            }
        }
    }

    Context 'system error occurred' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $true }
            Mock -ModuleName $moduleName Test-SystemAvailability { 'nothing-there' }
        }

        It 'returns error' {
            InModuleScope -ModuleName $moduleName {
                $result = Get-AddonStatus -Name 'test-addon' -Directory 'some-dir'

                $result.Error | Should -Be 'nothing-there'
            }
        }
    }

    Context 'addon is disabled' {
        BeforeAll {
            $addonName = 'test-addon'
            Mock -ModuleName $moduleName Test-Path { return $true }
            Mock -ModuleName $moduleName Test-SystemAvailability { return $null }
            Mock -ModuleName $moduleName Test-IsAddonEnabled { return $false } -ParameterFilter { $Addon.Name -eq $addonName } 
        }

        It 'returns addon-disabled status' {
            InModuleScope -ModuleName $moduleName -Parameters @{addonName = $addonName } {
                $result = Get-AddonStatus -Name $addonName -Directory 'some-dir'

                $result.Enabled | Should -BeFalse
            }
        }
    }

    Context 'addon is enabled' {
        BeforeAll {
            $addonName = 'test-addon'
            $addonDirectory = 'test-dir'
            $props = @{Name = 'p1' }, @{Name = 'p2' }
            Mock -ModuleName $moduleName Test-Path { return $true }
            Mock -ModuleName $moduleName Test-SystemAvailability { return $null }
            Mock -ModuleName $moduleName Test-IsAddonEnabled { return $true } -ParameterFilter { $Addon.Name -eq $addonName }
            Mock -ModuleName $moduleName Invoke-Script { return $props } -ParameterFilter { $FilePath -match "$addonDirectory\\Get-Status.ps1" }
        }

        It 'returns addon-enabled status' {
            InModuleScope -ModuleName $moduleName -Parameters @{addonName = $addonName ; addonDirectory = $addonDirectory } {
                $result = Get-AddonStatus -Name $addonName -Directory $addonDirectory

                $result.Enabled | Should -BeTrue
            }
        }

        It 'returns addon-specific props' {
            InModuleScope -ModuleName $moduleName -Parameters @{addonName = $addonName; addonDirectory = $addonDirectory; props = $props } {
                $result = Get-AddonStatus -Name $addonName -Directory $addonDirectory

                $result.Props | Should -Be $props
            }
        }
    }
}

Describe 'Get-IngressNginxGatewayConfig' -Tag 'unit', 'ci', 'addon' {
    It 'returns correct path' {
        InModuleScope -ModuleName $moduleName {
            $result = Get-IngressNginxGatewayConfig

            $result | Should -Be 'ingress-nginx-gw'
        }
    }
}

Describe 'Get-IngressNginxGatewaySecureConfig' -Tag 'unit', 'ci', 'addon' {
    It 'returns correct secure path' {
        InModuleScope -ModuleName $moduleName {
            $result = Get-IngressNginxGatewaySecureConfig

            $result | Should -Be 'ingress-nginx-gw-secure'
        }
    }
}

Describe 'Update-IngressForNginxGateway' -Tag 'unit', 'ci', 'addon' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log { }
        Mock -ModuleName $moduleName Test-IsAddonEnabled { return $false }
        Mock -ModuleName $moduleName Update-IngressForAddon { }
        Mock -ModuleName $moduleName Invoke-Kubectl { }
    }

    Context 'security addon not enabled' {
        It 'applies non-secure config' {
            InModuleScope -ModuleName $moduleName {
                $testAddon = [pscustomobject]@{ Name = 'dashboard' }
                Update-IngressForNginxGateway -Addon $testAddon

                Should -Invoke Invoke-Kubectl -Times 1 -Scope Context -ParameterFilter {
                    $Params -contains 'apply' -and $Params -contains '-k'
                }
            }
        }
    }

    Context 'security addon enabled without keycloak and hydra' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-KeyCloakServiceAvailability { return $false }
            Mock -ModuleName $moduleName Test-HydraAvailability { return $false }
        }

        It 'applies non-secure config' {
            InModuleScope -ModuleName $moduleName {
                $testAddon = [pscustomobject]@{ Name = 'dashboard' }
                Update-IngressForNginxGateway -Addon $testAddon

                Should -Invoke Invoke-Kubectl -Times 1 -Scope Context -ParameterFilter {
                    $Params -contains 'apply' -and $Params -contains '-k'
                }
            }
        }
    }

    Context 'security addon enabled with keycloak' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-KeyCloakServiceAvailability { return $true }
            Mock -ModuleName $moduleName Test-HydraAvailability { return $false }
            Mock -ModuleName $moduleName Test-Path { return $true }
        }

        It 'applies secure config' {
            InModuleScope -ModuleName $moduleName {
                $testAddon = [pscustomobject]@{ Name = 'dashboard' }
                Update-IngressForNginxGateway -Addon $testAddon

                Should -Invoke Invoke-Kubectl -Times 1 -Scope Context -ParameterFilter {
                    $Params -contains 'apply' -and $Params -contains '-k'
                }
            }
        }
    }

    Context 'security addon enabled with hydra' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-KeyCloakServiceAvailability { return $false }
            Mock -ModuleName $moduleName Test-HydraAvailability { return $true }
            Mock -ModuleName $moduleName Test-Path { return $true }
        }

        It 'applies secure config' {
            InModuleScope -ModuleName $moduleName {
                $testAddon = [pscustomobject]@{ Name = 'dashboard' }
                Update-IngressForNginxGateway -Addon $testAddon

                Should -Invoke Invoke-Kubectl -Times 1 -Scope Context -ParameterFilter {
                    $Params -contains 'apply' -and $Params -contains '-k'
                }
            }
        }
    }
}
