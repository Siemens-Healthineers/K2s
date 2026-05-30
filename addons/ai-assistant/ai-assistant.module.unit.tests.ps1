# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
    $moduleName = (Import-Module "$PSScriptRoot\ai-assistant.module.psm1" -PassThru -Force).Name
}


Describe 'Get-AiAssistantManifestsDir' -Tag 'unit', 'ci', 'addon', 'ai-assistant' {
    It 'returns a path ending with manifests' {
        InModuleScope $moduleName {
            $result = Get-AiAssistantManifestsDir
            $result | Should -BeLike '*\manifests'
        }
    }
}

Describe 'Get-KagentManifestsDir' -Tag 'unit', 'ci', 'addon', 'ai-assistant' {
    It 'returns a path ending with kagent' {
        InModuleScope $moduleName {
            $result = Get-KagentManifestsDir
            $result | Should -BeLike '*\kagent'
        }
    }
}

Describe 'Get-KagentCrdsPath' -Tag 'unit', 'ci', 'addon', 'ai-assistant' {
    It 'returns a path ending with kagent-crds.yaml' {
        InModuleScope $moduleName {
            $result = Get-KagentCrdsPath
            $result | Should -BeLike '*\kagent-crds.yaml'
        }
    }
}

Describe 'Get-KagentCorePath' -Tag 'unit', 'ci', 'addon', 'ai-assistant' {
    It 'returns a path ending with kagent.yaml' {
        InModuleScope $moduleName {
            $result = Get-KagentCorePath
            $result | Should -BeLike '*\kagent.yaml'
        }
    }
}

Describe 'Get-KagentA2aProxyPath' -Tag 'unit', 'ci', 'addon', 'ai-assistant' {
    It 'returns a path ending with a2a-proxy.yaml' {
        InModuleScope $moduleName {
            $result = Get-KagentA2aProxyPath
            $result | Should -BeLike '*\a2a-proxy.yaml'
        }
    }
}


Describe 'Wait-ForKagentAvailable' -Tag 'unit', 'ci', 'addon', 'ai-assistant' {
    Context 'Kagent controller becomes ready' {
        BeforeAll {
            Mock -ModuleName $moduleName Wait-ForPodCondition { return $true }
            Mock -ModuleName $moduleName Write-Log {}
        }

        It 'returns true' {
            InModuleScope $moduleName {
                $result = Wait-ForKagentAvailable
                $result | Should -Be $true
            }
        }

        It 'calls Wait-ForPodCondition with correct label and namespace' {
            InModuleScope $moduleName {
                Wait-ForKagentAvailable
                Should -Invoke Wait-ForPodCondition -Times 1 -Scope Context -ParameterFilter {
                    $Label -match 'kagent' -and
                    $Namespace -eq 'kagent' -and
                    $Condition -eq 'Ready'
                }
            }
        }
    }

    Context 'Kagent controller does not become ready' {
        BeforeAll {
            Mock -ModuleName $moduleName Wait-ForPodCondition { return $false }
            Mock -ModuleName $moduleName Write-Log {}
        }

        It 'returns false' {
            InModuleScope $moduleName {
                $result = Wait-ForKagentAvailable
                $result | Should -Be $false
            }
        }
    }
}

Describe 'Invoke-OllamaModelPull' -Tag 'unit', 'ci', 'addon', 'ai-assistant' {
    Context 'Ollama is ready and model already exists' {
        BeforeAll {
            Mock -ModuleName $moduleName Wait-ForOllamaReady { return $true }
            Mock -ModuleName $moduleName Write-Log {}
            # curl.exe returns tags containing the model
            Mock -ModuleName $moduleName curl.exe { return '{"models":[{"name":"qwen2.5:7b"}]}' }
        }

        It 'skips pull when model already available' {
            InModuleScope $moduleName {
                { Invoke-OllamaModelPull -Model 'qwen2.5:7b' } | Should -Not -Throw
            }
        }
    }

    Context 'Ollama is not ready' {
        BeforeAll {
            Mock -ModuleName $moduleName Wait-ForOllamaReady { return $false }
            Mock -ModuleName $moduleName Write-Log {}
        }

        It 'throws when Ollama is not responding' {
            InModuleScope $moduleName {
                { Invoke-OllamaModelPull -Model 'qwen2.5:7b' } | Should -Throw '*not responding*'
            }
        }
    }
}

Describe 'Remove-AiAssistantResources' -Tag 'unit', 'ci', 'addon', 'ai-assistant' {
    Context 'full removal (KeepModelData = false)' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl {
                return [pscustomobject]@{ Success = $true; Output = '' }
            }
            Mock -ModuleName $moduleName Remove-CopilotAgent {}
            Mock -ModuleName $moduleName Remove-OllamaAgent {}
            Mock -ModuleName $moduleName Write-Log {}
        }


        It 'deletes the ai-assistant namespace' {
            InModuleScope $moduleName {
                Remove-AiAssistantResources
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'delete' -and $Params -contains 'namespace' -and $Params -contains 'ai-assistant'
                }
            }
        }

        It 'deletes the ollama-models PVC' {
            InModuleScope $moduleName {
                Remove-AiAssistantResources
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'delete' -and $Params -contains 'pvc' -and $Params -contains 'ollama-models'
                }
            }
        }

        It 'deletes the kagent namespace' {
            InModuleScope $moduleName {
                Remove-AiAssistantResources
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'delete' -and $Params -contains 'namespace' -and $Params -contains 'kagent'
                }
            }
        }
    }

    Context 'keep model data (KeepModelData = true)' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl {
                return [pscustomobject]@{ Success = $true; Output = '' }
            }
            Mock -ModuleName $moduleName Remove-CopilotAgent {}
            Mock -ModuleName $moduleName Remove-OllamaAgent {}
            Mock -ModuleName $moduleName Write-Log {}
        }

        It 'does NOT delete the ollama-models PVC when KeepModelData is set' {
            InModuleScope $moduleName {
                Remove-AiAssistantResources -KeepModelData
                Should -Invoke Invoke-Kubectl -Times 0 -Scope It -ParameterFilter {
                    $Params -contains 'delete' -and $Params -contains 'pvc' -and $Params -contains 'ollama-models'
                }
            }
        }

        It 'does NOT delete the ai-assistant namespace when KeepModelData is set' {
            InModuleScope $moduleName {
                Remove-AiAssistantResources -KeepModelData
                Should -Invoke Invoke-Kubectl -Times 0 -Scope It -ParameterFilter {
                    $Params -contains 'delete' -and $Params -contains 'namespace' -and $Params -contains 'ai-assistant'
                }
            }
        }
    }
}

Describe 'Write-AiAssistantUsageForUser' -Tag 'unit', 'ci', 'addon', 'ai-assistant' {
    BeforeEach {
        Mock -ModuleName $moduleName Write-Log {}
    }

    It 'writes log messages' {
        InModuleScope $moduleName {
            Write-AiAssistantUsageForUser
            Should -Invoke Write-Log -Times 1 -Scope It
        }
    }

    It 'mentions Kagent in usage notes' {
        InModuleScope $moduleName {
            Write-AiAssistantUsageForUser
            Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter {
                ($Messages -join ' ') -match 'Kagent'
            }
        }
    }
}

Describe 'Module exports correct public functions' -Tag 'unit', 'ci', 'addon', 'ai-assistant' {
    It 'exports Get-AiAssistantManifestsDir' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Get-AiAssistantManifestsDir' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Get-KagentManifestsDir' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Get-KagentManifestsDir' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Install-KagentFramework' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Install-KagentFramework' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Wait-ForKagentAvailable' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Wait-ForKagentAvailable' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Install-CopilotAgent' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Install-CopilotAgent' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Install-OllamaAgent' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Install-OllamaAgent' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Install-OllamaWindowsService' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Install-OllamaWindowsService' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Wait-ForOllamaReady' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Wait-ForOllamaReady' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Set-OllamaKeepAlive' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Set-OllamaKeepAlive' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Invoke-OllamaModelPull' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Invoke-OllamaModelPull' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Remove-AiAssistantResources' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Remove-AiAssistantResources' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Write-AiAssistantUsageForUser' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Write-AiAssistantUsageForUser' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Get-OllamaExePath' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Get-OllamaExePath' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Test-OllamaWindowsHealth' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Test-OllamaWindowsHealth' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Remove-OllamaWindowsService' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Remove-OllamaWindowsService' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Get-OllamaExePath' -Tag 'unit', 'ci', 'addon', 'ai-assistant' {
    Context 'Ollama is not installed' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-Command { return $null }
            Mock -ModuleName $moduleName Test-Path { return $false }
        }

        It 'throws a descriptive error with download URL' {
            InModuleScope $moduleName {
                { Get-OllamaExePath } | Should -Throw '*Ollama is not installed*'
            }
        }
    }

    Context 'Ollama is on PATH' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-Command {
                return [pscustomobject]@{ Source = 'C:\Tools\ollama.exe' }
            }
        }

        It 'returns the PATH-based exe location' {
            InModuleScope $moduleName {
                $result = Get-OllamaExePath
                $result | Should -Be 'C:\Tools\ollama.exe'
            }
        }
    }

    Context 'Ollama is at default install path' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-Command { return $null }
            Mock -ModuleName $moduleName Test-Path { return $true }
        }

        It 'returns the default path' {
            InModuleScope $moduleName {
                $result = Get-OllamaExePath
                $result | Should -BeLike '*Ollama\ollama.exe'
            }
        }
    }
}
