# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
    $moduleName = (Import-Module "$PSScriptRoot\security.module.psm1" -PassThru -Force).Name
}

Describe 'Wait-ForLinkerdAvailable' -Tag 'unit', 'ci', 'addon' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log { }
    }

    Context 'Linkerd pods become ready within timeout' {
        BeforeAll {
            Mock -ModuleName $moduleName Wait-ForPodCondition { return $true }
        }

        It 'returns true' {
            InModuleScope $moduleName {
                $result = Wait-ForLinkerdAvailable
                $result | Should -Be $true
            }
        }

        It 'waits for the linkerd namespace with correct label' {
            InModuleScope $moduleName {
                Wait-ForLinkerdAvailable
                Should -Invoke Wait-ForPodCondition -Times 1 -Scope It -ParameterFilter {
                    $Namespace -eq 'linkerd' -and $Label -eq 'linkerd.io/workload-ns=linkerd'
                }
            }
        }

        It 'uses a timeout of at least 360 seconds' {
            # Nightly run showed 180s was not enough on a loaded CI node (pods timed out at
            # exactly 3 min). The timeout must be >= 360s to give Linkerd sufficient headroom.
            InModuleScope $moduleName {
                Wait-ForLinkerdAvailable
                Should -Invoke Wait-ForPodCondition -Times 1 -Scope It -ParameterFilter {
                    $TimeoutSeconds -ge 360
                }
            }
        }
    }

    Context 'Linkerd pods do not become ready within timeout' {
        BeforeAll {
            Mock -ModuleName $moduleName Wait-ForPodCondition { return $false }
        }

        It 'returns false' {
            InModuleScope $moduleName {
                $result = Wait-ForLinkerdAvailable
                $result | Should -Be $false
            }
        }
    }
}

Describe 'Wait-ForTrustManagerAvailable' -Tag 'unit', 'ci', 'addon' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log { }
    }

    Context 'trust-manager pods become ready' {
        BeforeAll {
            Mock -ModuleName $moduleName Wait-ForPodCondition { return $true }
        }

        It 'returns true' {
            InModuleScope $moduleName {
                $result = Wait-ForTrustManagerAvailable
                $result | Should -Be $true
            }
        }

        It 'targets the cert-manager namespace with correct label' {
            InModuleScope $moduleName {
                Wait-ForTrustManagerAvailable
                Should -Invoke Wait-ForPodCondition -Times 1 -Scope It -ParameterFilter {
                    $Namespace -eq 'cert-manager' -and $Label -eq 'app.kubernetes.io/name=trust-manager'
                }
            }
        }
    }

    Context 'trust-manager pods do not become ready' {
        BeforeAll {
            Mock -ModuleName $moduleName Wait-ForPodCondition { return $false }
        }

        It 'returns false' {
            InModuleScope $moduleName {
                $result = Wait-ForTrustManagerAvailable
                $result | Should -Be $false
            }
        }
    }
}

Describe 'Confirm-EnhancedSecurityOn' -Tag 'unit', 'ci', 'addon' {
    It 'returns true when type is enhanced' {
        InModuleScope $moduleName {
            $result = Confirm-EnhancedSecurityOn -Type 'enhanced'
            $result | Should -Be $true
        }
    }

    It 'returns false when type is basic' {
        InModuleScope $moduleName {
            $result = Confirm-EnhancedSecurityOn -Type 'basic'
            $result | Should -Be $false
        }
    }

    It 'returns false when type is empty string' {
        InModuleScope $moduleName {
            $result = Confirm-EnhancedSecurityOn -Type ''
            $result | Should -Be $false
        }
    }
}

Describe 'Get-LinkerdConfigDirectory' -Tag 'unit', 'ci', 'addon' {
    It 'returns path ending with manifests\linkerd' {
        InModuleScope $moduleName {
            $result = Get-LinkerdConfigDirectory
            $result | Should -Match 'manifests\\linkerd$'
        }
    }
}

Describe 'Get-LinkerdConfigTrustManager' -Tag 'unit', 'ci', 'addon' {
    It 'returns path ending with trust-manager.yaml' {
        InModuleScope $moduleName {
            $result = Get-LinkerdConfigTrustManager
            $result | Should -Match 'trust-manager\.yaml$'
        }
    }
}

Describe 'Get-LinkerdConfigCertManager' -Tag 'unit', 'ci', 'addon' {
    It 'returns path ending with linkerd-cert-manager.yaml' {
        InModuleScope $moduleName {
            $result = Get-LinkerdConfigCertManager
            $result | Should -Match 'linkerd-cert-manager\.yaml$'
        }
    }
}

Describe 'Get-LinkerdConfigCNI' -Tag 'unit', 'ci', 'addon' {
    It 'returns path ending with linkerd-cni-plugin-sa.yaml' {
        InModuleScope $moduleName {
            $result = Get-LinkerdConfigCNI
            $result | Should -Match 'linkerd-cni-plugin-sa\.yaml$'
        }
    }
}

Describe 'Remove-LinkerdMarkerConfig' -Tag 'unit', 'ci', 'addon' {
    Context 'marker file exists' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $true }
            Mock -ModuleName $moduleName Remove-Item { }
            Mock -ModuleName $moduleName Get-EnhancedSecurityFileLocation { return 'C:\fake\enhancedsecurity.json' }
        }

        It 'deletes the marker file' {
            InModuleScope $moduleName {
                Remove-LinkerdMarkerConfig
                Should -Invoke Remove-Item -Times 1 -Scope It -ParameterFilter {
                    $Path -match 'enhancedsecurity\.json'
                }
            }
        }
    }

    Context 'marker file does not exist' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $false }
            Mock -ModuleName $moduleName Remove-Item { }
        }

        It 'does not call Remove-Item' {
            InModuleScope $moduleName {
                Remove-LinkerdMarkerConfig
                Should -Invoke Remove-Item -Times 0 -Scope It
            }
        }
    }
}

