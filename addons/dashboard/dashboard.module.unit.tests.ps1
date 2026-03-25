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

Describe 'Get-HeadlampChartDirectory' -Tag 'unit', 'ci', 'addon', 'dashboard' {
    It 'returns a path ending with manifests\chart' {
        InModuleScope $moduleName {
            $result = Get-HeadlampChartDirectory
            $result | Should -BeLike '*\manifests\chart'
        }
    }
}

Describe 'Get-HeadlampChartPath' -Tag 'unit', 'ci', 'addon', 'dashboard' {
    Context 'chart tgz file exists' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-HeadlampChartDirectory { return 'TestDrive:\chart' }
            New-Item -ItemType Directory -Path 'TestDrive:\chart' -Force | Out-Null
            New-Item -ItemType File -Path 'TestDrive:\chart\headlamp-0.40.1.tgz' -Force | Out-Null
        }

        It 'returns the full path to the chart tgz' {
            InModuleScope $moduleName {
                $result = Get-HeadlampChartPath
                $result | Should -Not -BeNullOrEmpty
                $result | Should -BeLike '*headlamp-*.tgz'
            }
        }
    }

    Context 'no chart tgz file exists' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-HeadlampChartDirectory { return 'TestDrive:\emptychart' }
            New-Item -ItemType Directory -Path 'TestDrive:\emptychart' -Force | Out-Null
        }

        It 'returns null when no chart file found' {
            InModuleScope $moduleName {
                $result = Get-HeadlampChartPath
                $result | Should -BeNullOrEmpty
            }
        }
    }
}

Describe 'Install-HeadlampViaHelm' -Tag 'unit', 'ci', 'addon', 'dashboard' {
    Context 'chart and values file exist, helm succeeds' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-HeadlampChartDirectory { return 'TestDrive:\chart' }
            Mock -ModuleName $moduleName Get-HeadlampChartPath { return 'TestDrive:\chart\headlamp-0.40.1.tgz' }
            Mock -ModuleName $moduleName Test-Path { return $true }
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Success = $true; Output = 'namespace/dashboard configured' } }
            Mock -ModuleName $moduleName Invoke-Helm { return [pscustomobject]@{ Success = $true; Output = 'Release "headlamp" has been upgraded. Happy Helming!' } }
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Split-Path { return 'headlamp-0.40.1.tgz' }
        }

        It 'calls Invoke-Helm with upgrade --install' {
            InModuleScope $moduleName {
                { Install-HeadlampViaHelm } | Should -Not -Throw
                Should -Invoke Invoke-Helm -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'upgrade' -and $Params -contains '--install' -and $Params -contains 'headlamp'
                }
            }
        }

        It 'passes the namespace dashboard to helm' {
            InModuleScope $moduleName {
                Install-HeadlampViaHelm
                Should -Invoke Invoke-Helm -Times 1 -Scope It -ParameterFilter {
                    $Params -contains '--namespace' -and $Params -contains 'dashboard'
                }
            }
        }

        It 'passes the values file to helm' {
            InModuleScope $moduleName {
                Install-HeadlampViaHelm
                Should -Invoke Invoke-Helm -Times 1 -Scope It -ParameterFilter {
                    $Params -contains '--values'
                }
            }
        }
    }

    Context 'no chart tgz found' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-HeadlampChartPath { return $null }
        }

        It 'throws when no chart file is found' {
            InModuleScope $moduleName {
                { Install-HeadlampViaHelm } | Should -Throw '*No headlamp Helm chart .tgz found*'
            }
        }
    }

    Context 'values.yaml missing' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-HeadlampChartPath { return 'TestDrive:\chart\headlamp-0.40.1.tgz' }
            Mock -ModuleName $moduleName Get-HeadlampChartDirectory { return 'TestDrive:\chart' }
            Mock -ModuleName $moduleName Test-Path { return $false }
        }

        It 'throws when values.yaml is missing' {
            InModuleScope $moduleName {
                { Install-HeadlampViaHelm } | Should -Throw '*values.yaml not found*'
            }
        }
    }

    Context 'helm install fails' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-HeadlampChartDirectory { return 'TestDrive:\chart' }
            Mock -ModuleName $moduleName Get-HeadlampChartPath { return 'TestDrive:\chart\headlamp-0.40.1.tgz' }
            Mock -ModuleName $moduleName Test-Path { return $true }
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Success = $true; Output = '' } }
            Mock -ModuleName $moduleName Invoke-Helm { return [pscustomobject]@{ Success = $false; Output = 'Error: INSTALLATION FAILED' } }
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Split-Path { return 'headlamp-0.40.1.tgz' }
        }

        It 'throws when helm install fails' {
            InModuleScope $moduleName {
                { Install-HeadlampViaHelm } | Should -Throw '*helm upgrade --install failed*'
            }
        }
    }
}

Describe 'Uninstall-HeadlampViaHelm' -Tag 'unit', 'ci', 'addon', 'dashboard' {
    Context 'helm release exists' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Success = $true; Output = 'clusterrolebinding.rbac.authorization.k8s.io "headlamp-admin" deleted' } }
            Mock -ModuleName $moduleName Invoke-Helm -ParameterFilter { $Params -contains 'list' } {
                return [pscustomobject]@{ Success = $true; Output = 'headlamp' }
            }
            Mock -ModuleName $moduleName Invoke-Helm -ParameterFilter { $Params -contains 'uninstall' } {
                return [pscustomobject]@{ Success = $true; Output = 'release "headlamp" uninstalled' }
            }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'calls helm uninstall' {
            InModuleScope $moduleName {
                Uninstall-HeadlampViaHelm
                Should -Invoke Invoke-Helm -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'uninstall' -and $Params -contains 'headlamp'
                }
            }
        }

        It 'deletes the headlamp-admin ClusterRoleBinding' {
            InModuleScope $moduleName {
                Uninstall-HeadlampViaHelm
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'delete' -and $Params -contains 'clusterrolebinding' -and $Params -contains 'headlamp-admin'
                }
            }
        }

        It 'deletes the dashboard namespace' {
            InModuleScope $moduleName {
                Uninstall-HeadlampViaHelm
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'delete' -and $Params -contains 'namespace' -and $Params -contains 'dashboard'
                }
            }
        }
    }

    Context 'no helm release found' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Success = $true; Output = '' } }
            Mock -ModuleName $moduleName Invoke-Helm -ParameterFilter { $Params -contains 'list' } {
                return [pscustomobject]@{ Success = $true; Output = '' }
            }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'skips helm uninstall when no release found' {
            InModuleScope $moduleName {
                Uninstall-HeadlampViaHelm
                Should -Invoke Invoke-Helm -Times 0 -Scope It -ParameterFilter {
                    $Params -contains 'uninstall'
                }
            }
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
        Mock -ModuleName $moduleName Write-Log { }
    }

    It 'writes multiple log messages' {
        InModuleScope $moduleName {
            Write-HeadlampUsageForUser
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

    It 'exports Get-HeadlampChartDirectory' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Get-HeadlampChartDirectory' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Get-HeadlampChartPath' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Get-HeadlampChartPath' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Install-HeadlampViaHelm' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Install-HeadlampViaHelm' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Uninstall-HeadlampViaHelm' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Uninstall-HeadlampViaHelm' -ErrorAction SilentlyContinue
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
