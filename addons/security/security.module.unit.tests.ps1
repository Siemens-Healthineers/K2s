# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
    $module = "$PSScriptRoot\security.module.psm1"

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
    $moduleName = (Import-Module $module -PassThru -Force).Name

    Mock -ModuleName $moduleName Write-Log { }
    Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Output = ''; Success = $true } }
}

Describe 'Enable-IngressForSecurity' -Tag 'unit', 'ci', 'addon', 'security' {
    Context 'Keycloak and OAuth2 Proxy both present (Scenario A)' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-KeycloakServiceAvailability { return $true }
            Mock -ModuleName $moduleName Test-OAuth2ProxyServiceAvailability { return $true }
        }

        It 'applies both traefik keycloak and oauth2-proxy manifests' {
            InModuleScope $moduleName { Enable-IngressForSecurity -Ingress 'traefik' }

            Should -Invoke -ModuleName $moduleName Invoke-Kubectl -Times 1 -Exactly -ParameterFilter {
                ($Params -contains 'apply') -and (($Params -join ' ') -like '*traefik-ingress-oauth2-proxy.yaml') }
            Should -Invoke -ModuleName $moduleName Invoke-Kubectl -Times 1 -Exactly -ParameterFilter {
                ($Params -contains 'apply') -and (($Params -join ' ') -like '*traefik-ingress-keycloak.yaml') }
        }

        It 'performs exactly two apply calls for traefik' {
            InModuleScope $moduleName { Enable-IngressForSecurity -Ingress 'traefik' }

            Should -Invoke -ModuleName $moduleName Invoke-Kubectl -Times 2 -Exactly -ParameterFilter { $Params -contains 'apply' }
        }
    }

    Context 'Keycloak present, OAuth2 Proxy absent (Scenario B)' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-KeycloakServiceAvailability { return $true }
            Mock -ModuleName $moduleName Test-OAuth2ProxyServiceAvailability { return $false }
        }

        It 'applies only the keycloak manifest, no oauth2-proxy manifest' {
            InModuleScope $moduleName { Enable-IngressForSecurity -Ingress 'traefik' }

            Should -Invoke -ModuleName $moduleName Invoke-Kubectl -Times 1 -Exactly -ParameterFilter {
                ($Params -contains 'apply') -and (($Params -join ' ') -like '*traefik-ingress-keycloak.yaml') }
            Should -Invoke -ModuleName $moduleName Invoke-Kubectl -Times 0 -Exactly -ParameterFilter {
                ($Params -contains 'apply') -and (($Params -join ' ') -like '*oauth2-proxy*') }
        }
    }

    Context 'Keycloak absent, OAuth2 Proxy present (Scenario C)' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-KeycloakServiceAvailability { return $false }
            Mock -ModuleName $moduleName Test-OAuth2ProxyServiceAvailability { return $true }
        }

        It 'applies only the oauth2-proxy manifest, no keycloak manifest' {
            InModuleScope $moduleName { Enable-IngressForSecurity -Ingress 'traefik' }

            Should -Invoke -ModuleName $moduleName Invoke-Kubectl -Times 1 -Exactly -ParameterFilter {
                ($Params -contains 'apply') -and (($Params -join ' ') -like '*traefik-ingress-oauth2-proxy.yaml') }
            Should -Invoke -ModuleName $moduleName Invoke-Kubectl -Times 0 -Exactly -ParameterFilter {
                ($Params -contains 'apply') -and (($Params -join ' ') -like '*traefik-ingress-keycloak.yaml') }
        }
    }

    Context 'Both Keycloak and OAuth2 Proxy absent (Scenario D)' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-KeycloakServiceAvailability { return $false }
            Mock -ModuleName $moduleName Test-OAuth2ProxyServiceAvailability { return $false }
        }

        It 'applies no manifests' {
            InModuleScope $moduleName { Enable-IngressForSecurity -Ingress 'traefik' }

            Should -Invoke -ModuleName $moduleName Invoke-Kubectl -Times 0 -Exactly -ParameterFilter { $Params -contains 'apply' }
        }

        It 'writes the skip log message' {
            InModuleScope $moduleName { Enable-IngressForSecurity -Ingress 'traefik' }

            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -ParameterFilter { "$Messages" -like '*Skipping security ingress creation*' }
        }
    }
}

Describe 'Remove-IngressForSecurity' -Tag 'unit', 'ci', 'addon', 'security' {
    Context 'split manifests exist, legacy combined manifests absent' {
        It 'deletes all split manifests safely' {
            InModuleScope $moduleName { Remove-IngressForSecurity }

            Should -Invoke -ModuleName $moduleName Invoke-Kubectl -Times 8 -Exactly -ParameterFilter { $Params -contains 'delete' }
        }
    }

    Context 'legacy combined manifests do not exist' {
        BeforeAll {
            # Real Test-Path: only split manifests are present on disk; legacy files removed.
            Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $Path -like '*-ingress.yaml' }
        }

        It 'does not delete legacy manifests and does not throw' {
            InModuleScope $moduleName { { Remove-IngressForSecurity } | Should -Not -Throw }

            Should -Invoke -ModuleName $moduleName Invoke-Kubectl -Times 0 -Exactly -ParameterFilter {
                ($Params -contains 'delete') -and (($Params -join ' ') -match 'traefik-ingress\.yaml|nginx-ingress\.yaml|nginx-gw-ingress\.yaml') }
        }
    }
}

