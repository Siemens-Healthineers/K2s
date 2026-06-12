# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Regression tests ensuring the optional Dashboard integration (Headlamp plugin sync)
never becomes a hard runtime dependency for other addons.

.DESCRIPTION
Several addons (security, monitoring, ingress/*, rollout/fluxcd) call
Sync-HeadlampPlugins from dashboard.module.psm1 purely as an optional UI
integration. In offline/minimal packages the dashboard addon may be absent.

These tests statically verify, for every non-dashboard addon script that
references Sync-HeadlampPlugins, that:
  1. the dashboard module is imported only when present  (Test-Path guard)
  2. the dashboard module is NOT in an unconditional Import-Module list
  3. Sync-HeadlampPlugins is only invoked when available  (Get-Command guard)

This guarantees the "dashboard module absent" and "dashboard module present"
scenarios both behave safely without executing a live cluster.
#>

BeforeAll {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
    $script:addonsRoot = $PSScriptRoot
}

# Defined at discovery scope so -ForEach data-driven cases expand correctly (Pester v5).
$script:addonsRootDiscovery = $PSScriptRoot
$script:guardedScripts = @(
    'security\Enable.ps1'
    'security\Disable.ps1'
    'security\Update.ps1'
    'monitoring\Enable.ps1'
    'monitoring\Disable.ps1'
    'monitoring\Update.ps1'
    'ingress\nginx\Enable.ps1'
    'ingress\nginx\Disable.ps1'
    'ingress\nginx-gw\Enable.ps1'
    'ingress\nginx-gw\Disable.ps1'
    'ingress\traefik\Enable.ps1'
    'ingress\traefik\Disable.ps1'
    'rollout\fluxcd\Enable.ps1'
    'rollout\fluxcd\Disable.ps1'
    'rollout\fluxcd\Update.ps1'
)

Describe 'Optional Dashboard integration (Headlamp plugin sync guards)' -Tag 'unit', 'ci', 'addon', 'dashboard', 'plugin' {

    It 'every guarded script exists on disk' {
        foreach ($rel in $script:guardedScripts) {
            $full = Join-Path $script:addonsRoot $rel
            (Test-Path $full) | Should -Be $true -Because "$rel should exist"
        }
    }

    It '<_> imports the dashboard module only behind a Test-Path guard' -ForEach $script:guardedScripts {
        $full = Join-Path $script:addonsRoot $_
        $content = Get-Content -LiteralPath $full -Raw

        # Must contain the guarded import.
        $content | Should -Match 'if \(Test-Path \$dashboardModule\)' -Because "$_ must guard the dashboard import"
        $content | Should -Match 'Import-Module \$dashboardModule -DisableNameChecking' -Because "$_ must import dashboard module guarded"
    }

    It '<_> never imports the dashboard module in an unconditional Import-Module list' -ForEach $script:guardedScripts {
        $full = Join-Path $script:addonsRoot $_
        $lines = Get-Content -LiteralPath $full

        # Any Import-Module line that lists $dashboardModule alongside other modules
        # (i.e. not the standalone guarded "Import-Module $dashboardModule ...") is forbidden.
        $offending = $lines | Where-Object {
            $_ -match 'Import-Module' -and
            $_ -match '\$dashboardModule' -and
            $_ -notmatch 'Import-Module \$dashboardModule -DisableNameChecking'
        }
        @($offending).Count | Should -Be 0 -Because "$_ must not hard-import dashboard module"
    }

    It '<_> calls Sync-HeadlampPlugins only behind a Get-Command guard' -ForEach $script:guardedScripts {
        $full = Join-Path $script:addonsRoot $_
        $content = Get-Content -LiteralPath $full -Raw

        # The script references the sync function...
        $content | Should -Match 'Sync-HeadlampPlugins'
        # ...and every reference is wrapped in the availability guard.
        $content | Should -Match 'if \(Get-Command Sync-HeadlampPlugins -ErrorAction SilentlyContinue\)' -Because "$_ must guard the call"

        # No bare, unguarded invocation at column 0 (the guarded call is indented inside the if).
        ($content -match '(?m)^Sync-HeadlampPlugins\s*$') | Should -Be $false -Because "$_ must not call Sync-HeadlampPlugins unguarded"
    }
}



