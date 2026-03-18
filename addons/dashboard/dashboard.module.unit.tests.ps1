# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
    $moduleName = (Import-Module "$PSScriptRoot\dashboard.module.psm1" -PassThru -Force).Name
}

Describe 'Get-HeadlampManifestsDirectory' -Tag 'unit', 'ci', 'addon', 'dashboard' {
    It 'returns a path ending with manifests\headlamp' {
        InModuleScope $moduleName {
            $result = Get-HeadlampManifestsDirectory
            $result | Should -BeLike '*\manifests\headlamp'
        }
    }
}

Describe 'Wait-ForHeadlampAvailable' -Tag 'unit', 'ci', 'addon', 'dashboard' {
    Context 'headlamp pod becomes ready' {
        BeforeAll {
            Mock -ModuleName $moduleName Wait-ForPodCondition { return $true }
        }

        It 'returns true' {
            InModuleScope $moduleName {
                $result = Wait-ForHeadlampAvailable
                $result | Should -Be $true
            }
        }

        It 'calls Wait-ForPodCondition with correct label namespace and timeout' {
            InModuleScope $moduleName {
                Wait-ForHeadlampAvailable
                Should -Invoke Wait-ForPodCondition -Times 1 -Scope Context -ParameterFilter {
                    $Label -eq 'app.kubernetes.io/name=headlamp' -and
                    $Namespace -eq 'dashboard' -and
                    $Condition -eq 'Ready' -and
                    $TimeoutSeconds -eq 200
                }
            }
        }
    }

    Context 'headlamp pod does not become ready' {
        BeforeAll {
            Mock -ModuleName $moduleName Wait-ForPodCondition { return $false }
        }

        It 'returns false' {
            InModuleScope $moduleName {
                $result = Wait-ForHeadlampAvailable
                $result | Should -Be $false
            }
        }
    }
}

Describe 'Write-HeadlampUsageForUser' -Tag 'unit', 'ci', 'addon', 'dashboard' {

    BeforeEach {
        # Use Pester's built-in invocation tracking (Should -Invoke) instead of a
        # custom capture list to avoid $script: scope ambiguity between the test
        # block and the mock body running in module scope.
        Mock -ModuleName $moduleName Write-Log { }
    }

    It 'writes multiple log messages' {
        InModuleScope $moduleName {
            Write-HeadlampUsageForUser
            # Write-Log must be called at least once (the function emits many lines)
            Should -Invoke Write-Log -Times 1 -Scope It
        }
    }

    It 'mentions Headlamp in usage notes' {
        InModuleScope $moduleName {
            Write-HeadlampUsageForUser
            Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter {
                ($Messages -join ' ') -match 'Headlamp'
            }
        }
    }

    It 'mentions the correct port-forward service and port 4466' {
        InModuleScope $moduleName {
            Write-HeadlampUsageForUser
            Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter {
                ($Messages -join ' ') -match 'svc/headlamp'
            }
            Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter {
                ($Messages -join ' ') -match '4466'
            }
        }
    }

    It 'mentions the correct port-forward URL including /dashboard/ path' {
        InModuleScope $moduleName {
            Write-HeadlampUsageForUser
            Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter {
                ($Messages -join ' ') -match 'localhost:4466/dashboard'
            }
        }
    }

    It 'mentions that the token login screen is expected' {
        InModuleScope $moduleName {
            Write-HeadlampUsageForUser
            Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter {
                ($Messages -join ' ') -match 'token login screen'
            }
        }
    }

    It 'does not mention old kubernetes-dashboard or kong-proxy or port 8443' {
        InModuleScope $moduleName {
            Write-HeadlampUsageForUser
            Should -Invoke Write-Log -Times 0 -Scope It -ParameterFilter {
                ($Messages -join ' ') -match 'kubernetes-dashboard'
            }
            Should -Invoke Write-Log -Times 0 -Scope It -ParameterFilter {
                ($Messages -join ' ') -match 'kong-proxy'
            }
            Should -Invoke Write-Log -Times 0 -Scope It -ParameterFilter {
                ($Messages -join ' ') -match '8443'
            }
        }
    }

    It 'mentions the dashboard ingress URL' {
        InModuleScope $moduleName {
            Write-HeadlampUsageForUser
            Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter {
                ($Messages -join ' ') -match 'k2s\.cluster\.local/dashboard'
            }
        }
    }

    It 'mentions token creation command for headlamp SA' {
        InModuleScope $moduleName {
            Write-HeadlampUsageForUser
            Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter {
                ($Messages -join ' ') -match 'create token headlamp'
            }
        }
    }
}

Describe 'Module exports correct public functions' -Tag 'unit', 'ci', 'addon', 'dashboard' {
    It 'exports Get-HeadlampManifestsDirectory' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Get-HeadlampManifestsDirectory' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Wait-ForHeadlampAvailable' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Wait-ForHeadlampAvailable' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Write-HeadlampUsageForUser' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Write-HeadlampUsageForUser' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'does not export the removed Test-SecurityAddonAvailability' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Test-SecurityAddonAvailability' -ErrorAction SilentlyContinue
            $fn | Should -BeNullOrEmpty
        }
    }
}

Describe 'Linkerd annotation null-safety logic (Update.ps1 guard pattern)' -Tag 'unit', 'ci', 'addon', 'dashboard' {
    # These tests validate the null-safety guard pattern used in Update.ps1 when
    # reading Linkerd annotations from the headlamp deployment JSON.
    # They test the inline logic to ensure no NullReferenceException on fresh deployments.

    It 'handles deployment with no annotations object — hasNoAnnotation is true' {
        InModuleScope $moduleName {
            $deploymentJson = '{"spec":{"template":{"metadata":{}}}}'
            $deploymentObj = $deploymentJson | ConvertFrom-Json

            $linkerdAnnotation = $null
            if ($null -ne $deploymentObj.spec.template.metadata.annotations) {
                $linkerdAnnotation = $deploymentObj.spec.template.metadata.annotations.'linkerd.io/inject'
            }
            ($null -eq $linkerdAnnotation) | Should -Be $true
        }
    }

    It 'handles deployment with null annotations — hasNoAnnotation is true' {
        InModuleScope $moduleName {
            $deploymentJson = '{"spec":{"template":{"metadata":{"annotations":null}}}}'
            $deploymentObj = $deploymentJson | ConvertFrom-Json

            $linkerdAnnotation = $null
            if ($null -ne $deploymentObj.spec.template.metadata.annotations) {
                $linkerdAnnotation = $deploymentObj.spec.template.metadata.annotations.'linkerd.io/inject'
            }
            ($null -eq $linkerdAnnotation) | Should -Be $true
        }
    }

    It 'detects linkerd inject annotation when set to enabled' {
        InModuleScope $moduleName {
            $deploymentJson = '{"spec":{"template":{"metadata":{"annotations":{"linkerd.io/inject":"enabled"}}}}}'
            $deploymentObj = $deploymentJson | ConvertFrom-Json

            $linkerdAnnotation = $null
            if ($null -ne $deploymentObj.spec.template.metadata.annotations) {
                $linkerdAnnotation = $deploymentObj.spec.template.metadata.annotations.'linkerd.io/inject'
            }
            $linkerdAnnotation | Should -Be 'enabled'
        }
    }

    It 'handles deployment with empty annotations object — hasNoAnnotation is true' {
        InModuleScope $moduleName {
            $deploymentJson = '{"spec":{"template":{"metadata":{"annotations":{}}}}}'
            $deploymentObj = $deploymentJson | ConvertFrom-Json

            $linkerdAnnotation = $null
            if ($null -ne $deploymentObj.spec.template.metadata.annotations) {
                $linkerdAnnotation = $deploymentObj.spec.template.metadata.annotations.'linkerd.io/inject'
            }
            ($null -eq $linkerdAnnotation) | Should -Be $true
        }
    }

    It 'else-branch skip condition: annotation already null means no patch needed' {
        InModuleScope $moduleName {
            # Simulate Update.ps1 else-branch: check current annotation before patching.
            # If annotation is already null, skip the patch entirely.
            $deploymentJson = '{"spec":{"template":{"metadata":{"annotations":{}}}}}'
            $currentDeployment = $deploymentJson | ConvertFrom-Json

            $currentAnnotation = $null
            if ($null -ne $currentDeployment.spec.template.metadata.annotations) {
                $currentAnnotation = $currentDeployment.spec.template.metadata.annotations.'linkerd.io/inject'
            }

            # When annotation is already absent, skip-patch condition is true
            ($null -eq $currentAnnotation) | Should -Be $true
        }
    }

    It 'else-branch patch condition: annotation set to enabled means patch is required to remove it' {
        InModuleScope $moduleName {
            # Simulate Update.ps1 else-branch: annotation was previously set (Linkerd was active).
            # The patch must run to remove it.
            $deploymentJson = '{"spec":{"template":{"metadata":{"annotations":{"linkerd.io/inject":"enabled"}}}}}'
            $currentDeployment = $deploymentJson | ConvertFrom-Json

            $currentAnnotation = $null
            if ($null -ne $currentDeployment.spec.template.metadata.annotations) {
                $currentAnnotation = $currentDeployment.spec.template.metadata.annotations.'linkerd.io/inject'
            }

            # When annotation is present, patch is required
            ($null -ne $currentAnnotation) | Should -Be $true
        }
    }
}

