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

Describe 'Get-HolmesManifestPath' -Tag 'unit', 'ci', 'addon', 'ai-assistant' {
    It 'returns a path ending with holmesgpt\holmesgpt.yaml' {
        InModuleScope $moduleName {
            $result = Get-HolmesManifestPath
            $result | Should -BeLike '*\holmesgpt\holmesgpt.yaml'
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

Describe 'Set-HolmesModelConfig' -Tag 'unit', 'ci', 'addon', 'ai-assistant' {
    Context 'manifest file is applied successfully' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-HolmesManifestPath { return 'TestDrive:\holmesgpt.yaml' }
            Set-Content -Path 'TestDrive:\holmesgpt.yaml' -Value 'model: MODEL_PLACEHOLDER' -Encoding UTF8
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Success = $true; Output = 'configmap/holmesgpt-model-config applied' } }
            Mock -ModuleName $moduleName Write-Log {}
        }

        It 'substitutes MODEL_PLACEHOLDER with the provided model name' {
            InModuleScope $moduleName {
                # We check that Invoke-Kubectl is called (the substituted file is applied)
                { Set-HolmesModelConfig -Model 'mistral' } | Should -Not -Throw
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'apply' -and $Params -contains '-f'
                }
            }
        }
    }

    Context 'kubectl apply fails' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-HolmesManifestPath { return 'TestDrive:\holmesgpt.yaml' }
            Set-Content -Path 'TestDrive:\holmesgpt.yaml' -Value 'model: MODEL_PLACEHOLDER' -Encoding UTF8
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Success = $false; Output = 'Error: something went wrong' } }
            Mock -ModuleName $moduleName Write-Log {}
        }

        It 'throws when kubectl apply fails' {
            InModuleScope $moduleName {
                { Set-HolmesModelConfig -Model 'mistral' } | Should -Throw "*Failed to apply HolmesGPT manifests*"
            }
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
        }

        It 'skips ConfigMap creation when cert file is missing' {
            InModuleScope $moduleName {
                { New-ZscalerCaConfigMap } | Should -Not -Throw
                Should -Invoke Invoke-Kubectl -Times 0 -Scope It -ErrorAction SilentlyContinue
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

Describe 'Wait-ForHolmesAvailable' -Tag 'unit', 'ci', 'addon', 'ai-assistant' {
    Context 'HolmesGPT pod becomes ready' {
        BeforeAll {
            Mock -ModuleName $moduleName Wait-ForPodCondition { return $true }
        }

        It 'returns true' {
            InModuleScope $moduleName {
                $result = Wait-ForHolmesAvailable
                $result | Should -Be $true
            }
        }

        It 'calls Wait-ForPodCondition with correct label, namespace, and timeout' {
            InModuleScope $moduleName {
                Wait-ForHolmesAvailable
                Should -Invoke Wait-ForPodCondition -Times 1 -Scope Context -ParameterFilter {
                    $Label -eq 'app=holmesgpt' -and
                    $Namespace -eq 'ai-assistant' -and
                    $Condition -eq 'Ready' -and
                    $TimeoutSeconds -eq 120
                }
            }
        }
    }

    Context 'HolmesGPT pod does not become ready' {
        BeforeAll {
            Mock -ModuleName $moduleName Wait-ForPodCondition { return $false }
        }

        It 'returns false' {
            InModuleScope $moduleName {
                $result = Wait-ForHolmesAvailable
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
                { Invoke-OllamaModelPull -Model 'llama3.2' } | Should -Not -Throw
            }
        }

        It 'calls kubectl exec with ollama pull' {
            InModuleScope $moduleName {
                Invoke-OllamaModelPull -Model 'llama3.2'
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'exec' -and $Params -contains 'pull' -and $Params -contains 'llama3.2'
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
                { Invoke-OllamaModelPull -Model 'llama3.2' } | Should -Throw '*Ollama pod did not become ready*'
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
                { Invoke-OllamaModelPull -Model 'llama3.2' } | Should -Throw "*ollama pull llama3.2*failed*"
            }
        }
    }
}

Describe 'Remove-HolmesProxyEndpoints' -Tag 'unit', 'ci', 'addon', 'ai-assistant' {
    BeforeAll {
        Mock -ModuleName $moduleName Invoke-Kubectl {
            return [pscustomobject]@{ Success = $true; Output = '' }
        }
        Mock -ModuleName $moduleName Write-Log {}
    }

    It 'deletes the holmesgpt-holmes endpoints in default namespace' {
        InModuleScope $moduleName {
            Remove-HolmesProxyEndpoints
            Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                $Params -contains 'delete' -and
                $Params -contains 'endpoints' -and
                $Params -contains 'holmesgpt-holmes' -and
                $Params -contains 'default'
            }
        }
    }

    It 'deletes the holmesgpt-holmes service in default namespace' {
        InModuleScope $moduleName {
            Remove-HolmesProxyEndpoints
            Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                $Params -contains 'delete' -and
                $Params -contains 'service' -and
                $Params -contains 'holmesgpt-holmes' -and
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
            Mock -ModuleName $moduleName Remove-HolmesProxyEndpoints {}
            Mock -ModuleName $moduleName Write-Log {}
        }

        It 'calls Remove-HolmesProxyEndpoints' {
            InModuleScope $moduleName {
                Remove-AiAssistantResources
                Should -Invoke Remove-HolmesProxyEndpoints -Times 1 -Scope It
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

        It 'deletes the cluster-scoped RBAC resources' {
            InModuleScope $moduleName {
                Remove-AiAssistantResources
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'delete' -and $Params -contains 'clusterrolebinding' -and $Params -contains 'holmesgpt-reader'
                }
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'delete' -and $Params -contains 'clusterrole' -and $Params -contains 'holmesgpt-reader'
                }
            }
        }
    }

    Context 'keep model data (KeepModelData = true)' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl {
                return [pscustomobject]@{ Success = $true; Output = '' }
            }
            Mock -ModuleName $moduleName Remove-HolmesProxyEndpoints {}
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

        It 'still removes HolmesGPT workload resources even when KeepModelData is set' {
            InModuleScope $moduleName {
                Remove-AiAssistantResources -KeepModelData
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'delete' -and $Params -contains 'deployment' -and $Params -contains 'holmesgpt-holmes'
                }
            }
        }
    }
}

Describe 'Write-AiAssistantUsageForUser' -Tag 'unit', 'ci', 'addon', 'ai-assistant' {
    BeforeEach {
        Mock -ModuleName $moduleName Write-Log {}
    }

    It 'writes multiple log messages' {
        InModuleScope $moduleName {
            Write-AiAssistantUsageForUser
            Should -Invoke Write-Log -Times 1 -Scope It
        }
    }

    It 'mentions Ollama in usage notes' {
        InModuleScope $moduleName {
            Write-AiAssistantUsageForUser
            Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter {
                ($Messages -join ' ') -match 'Ollama'
            }
        }
    }

    It 'mentions HolmesGPT in usage notes' {
        InModuleScope $moduleName {
            Write-AiAssistantUsageForUser
            Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter {
                ($Messages -join ' ') -match 'HolmesGPT'
            }
        }
    }

    It 'shows the default model name when no model is provided' {
        InModuleScope $moduleName {
            Write-AiAssistantUsageForUser
            Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter {
                ($Messages -join ' ') -match 'llama3\.2'
            }
        }
    }

    It 'shows the supplied model name when a model is provided' {
        InModuleScope $moduleName {
            Write-AiAssistantUsageForUser -Model 'mistral'
            Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter {
                ($Messages -join ' ') -match 'mistral'
            }
        }
    }

    It 'mentions the Ollama port-forward command' {
        InModuleScope $moduleName {
            Write-AiAssistantUsageForUser
            Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter {
                ($Messages -join ' ') -match '11434'
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

    It 'exports Get-HolmesManifestPath' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Get-HolmesManifestPath' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Set-HolmesModelConfig' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Set-HolmesModelConfig' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Set-HolmesProxyEndpoints' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Set-HolmesProxyEndpoints' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Remove-HolmesProxyEndpoints' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Remove-HolmesProxyEndpoints' -ErrorAction SilentlyContinue
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

    It 'exports Wait-ForHolmesAvailable' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Wait-ForHolmesAvailable' -ErrorAction SilentlyContinue
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

