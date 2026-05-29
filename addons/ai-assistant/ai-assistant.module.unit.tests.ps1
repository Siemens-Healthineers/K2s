# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
    $moduleName = (Import-Module "$PSScriptRoot\ai-assistant.module.psm1" -PassThru -Force).Name
}

Describe 'Get-OllamaManifestPath' -Tag 'unit', 'ci', 'addon', 'ai-assistant' {
    It 'returns a path ending with ollama\ollama.yaml' {
        InModuleScope $moduleName {
            $result = Get-OllamaManifestPath
            $result | Should -BeLike '*\ollama\ollama.yaml'
        }
    }
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

Describe 'New-OllamaDataDirectory' -Tag 'unit', 'ci', 'addon', 'ai-assistant' {
    Context 'SSH command succeeds' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey {
                return [pscustomobject]@{ Output = '' }
            }
            Mock -ModuleName $moduleName Write-Log {}
        }

        It 'calls Invoke-CmdOnControlPlaneViaSSHKey with mkdir command' {
            InModuleScope $moduleName {
                { New-OllamaDataDirectory } | Should -Not -Throw
                Should -Invoke Invoke-CmdOnControlPlaneViaSSHKey -Times 1 -Scope It -ParameterFilter {
                    $CmdToExecute -match 'mkdir' -and $CmdToExecute -match '/data/ollama'
                }
            }
        }
    }
}

Describe 'New-ZscalerCaConfigMap' -Tag 'unit', 'ci', 'addon', 'ai-assistant' {
    Context 'cert file does not exist' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $false }
            Mock -ModuleName $moduleName Write-Log {}
             Mock -ModuleName $moduleName Invoke-Kubectl {}
        }

        It 'skips ConfigMap creation when cert file is missing' {
            InModuleScope $moduleName {
                { New-ZscalerCaConfigMap } | Should -Not -Throw
                Should -Invoke Invoke-Kubectl -Times 0 -Scope It -ModuleName $moduleName
            }
        }

        It 'logs a warning about missing cert' {
            InModuleScope $moduleName {
                New-ZscalerCaConfigMap
                Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter {
                    ($Messages -join ' ') -match 'Warning' -or ($_ -match 'Warning')
                }
            }
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
    Context 'Ollama is ready and model pull succeeds' {
        BeforeAll {
            Mock -ModuleName $moduleName Wait-ForPodCondition { return $true }
            Mock -ModuleName $moduleName Invoke-Kubectl {
                return [pscustomobject]@{ Success = $true; Output = 'pulling manifest ... success' }
            }
            Mock -ModuleName $moduleName Write-Log {}
        }

        It 'does not throw when model pull succeeds' {
            InModuleScope $moduleName {
                { Invoke-OllamaModelPull -Model 'qwen2.5:7b' } | Should -Not -Throw
            }
        }

        It 'calls kubectl exec with ollama pull' {
            InModuleScope $moduleName {
                Invoke-OllamaModelPull -Model 'qwen2.5:7b'
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'exec' -and $Params -contains 'pull' -and $Params -contains 'qwen2.5:7b'
                }
            }
        }
    }

    Context 'Ollama pod does not become ready' {
        BeforeAll {
            Mock -ModuleName $moduleName Wait-ForPodCondition { return $false }
            Mock -ModuleName $moduleName Write-Log {}
        }

        It 'throws when Ollama pod is not ready within timeout' {
            InModuleScope $moduleName {
                { Invoke-OllamaModelPull -Model 'qwen2.5:7b' } | Should -Throw '*Ollama pod did not become ready*'
            }
        }
    }

    Context 'ollama pull command fails' {
        BeforeAll {
            Mock -ModuleName $moduleName Wait-ForPodCondition { return $true }
            Mock -ModuleName $moduleName Invoke-Kubectl {
                return [pscustomobject]@{ Success = $false; Output = 'Error: pull failed' }
            }
            Mock -ModuleName $moduleName Write-Log {}
        }

        It 'throws when ollama pull returns failure' {
            InModuleScope $moduleName {
                { Invoke-OllamaModelPull -Model 'qwen2.5:7b' } | Should -Throw "*ollama pull qwen2.5:7b*failed*"
            }
        }
    }
}

Describe 'Remove-KagentProxyService' -Tag 'unit', 'ci', 'addon', 'ai-assistant' {
    BeforeAll {
        Mock -ModuleName $moduleName Invoke-Kubectl {
            return [pscustomobject]@{ Success = $true; Output = '' }
        }
        Mock -ModuleName $moduleName Write-Log {}
    }

    It 'deletes legacy proxy services in default namespace' {
        InModuleScope $moduleName {
            Remove-KagentProxyService
            Should -Invoke Invoke-Kubectl -Scope It -ParameterFilter {
                $Params -contains 'delete' -and
                $Params -contains 'service' -and
                $Params -contains 'default'
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
            Mock -ModuleName $moduleName Remove-KagentProxyService {}
            Mock -ModuleName $moduleName Remove-LegacyAgentResources {}
            Mock -ModuleName $moduleName Write-Log {}
        }

        It 'calls Remove-LegacyAgentResources' {
            InModuleScope $moduleName {
                Remove-AiAssistantResources
                Should -Invoke Remove-LegacyAgentResources -Times 1 -Scope It
            }
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
            Mock -ModuleName $moduleName Remove-KagentProxyService {}
            Mock -ModuleName $moduleName Remove-LegacyAgentResources {}
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

    It 'exports Get-OllamaManifestPath' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Get-OllamaManifestPath' -ErrorAction SilentlyContinue
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

    It 'exports Set-KagentProxyService' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Set-KagentProxyService' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Remove-KagentProxyService' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Remove-KagentProxyService' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Remove-LegacyAgentResources' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Remove-LegacyAgentResources' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports New-OllamaDataDirectory' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'New-OllamaDataDirectory' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports New-ZscalerCaConfigMap' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'New-ZscalerCaConfigMap' -ErrorAction SilentlyContinue
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
}
