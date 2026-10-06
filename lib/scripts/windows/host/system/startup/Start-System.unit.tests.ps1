# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

BeforeAll {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        "$PSScriptRoot\Start-System.ps1", [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw ($parseErrors | Out-String)
    }
    $functionNames = @(
        'Get-MissingWindowsPodRoutesOnControlPlane',
        'Restore-ControlPlaneTransitRoute',
        'Wait-ForControlPlaneTransitReachability',
        'Restart-FlannelDaemonSetWithWindowsRouteRepair'
    )
    foreach ($function in $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $functionNames
            }, $true)) {
        Invoke-Expression $function.Extent.Text
    }

    function Write-Log { param($Messages, [switch]$Console) }
    function Invoke-CmdOnControlPlaneViaSSHKey { param($CmdToExecute, [switch]$IgnoreErrors, [switch]$NoLog) }
    function Get-LoopbackAdapterCIDR { }
    function Get-ConfiguredKubeSwitchIP { }
    function Get-WindowsWorkerNodeRoutes { param($KubeConfigPath) }
    function Invoke-KubectlWithKubeConfig { param($KubeConfigPath, $Params) }
    $logUseCase = 'Start-System'
}

Describe 'Startup route inspection and repair' -Tag 'unit', 'ci', 'startup' {
    BeforeEach {
        $nodeRoutes = @([pscustomobject]@{ PodCIDR = '172.20.1.0/24'; InternalIP = '172.22.1.2'; NodeName = 'windows' })
        Mock Write-Log {}
        Mock Start-Sleep {}
        Mock Get-LoopbackAdapterCIDR { '172.22.1.0/24' }
        Mock Get-ConfiguredKubeSwitchIP { '172.19.1.1' }
        Mock Invoke-CmdOnControlPlaneViaSSHKey { [pscustomobject]@{ Success = $true; ExitCode = 0; Output = '' } }
    }

    It 'does not classify failed SSH output as a missing pod route' {
        Mock Invoke-CmdOnControlPlaneViaSSHKey {
            [pscustomobject]@{ Success = $false; ExitCode = 255; Output = 'UNPROTECTED PRIVATE KEY FILE!' }
        }
        { Get-MissingWindowsPodRoutesOnControlPlane -WindowsNodeRoutes $nodeRoutes } |
            Should -Throw '*Cannot inspect Windows pod route*UNPROTECTED PRIVATE KEY FILE*'
    }

    It 'does not accept matching route text from a failed command' {
        Mock Invoke-CmdOnControlPlaneViaSSHKey {
            [pscustomobject]@{ Success = $false; ExitCode = 1; Output = '172.20.1.0/24 via 172.22.1.2' }
        }
        { Get-MissingWindowsPodRoutesOnControlPlane -WindowsNodeRoutes $nodeRoutes } |
            Should -Throw '*Cannot inspect Windows pod route*'
    }

    It 'recognizes a successful existing pod route' {
        Mock Invoke-CmdOnControlPlaneViaSSHKey {
            [pscustomobject]@{ Success = $true; ExitCode = 0; Output = '172.20.1.0/24 via 172.22.1.2 dev eth0' }
        }
        @(Get-MissingWindowsPodRoutesOnControlPlane -WindowsNodeRoutes $nodeRoutes).Count | Should -Be 0
    }

    It 'reports genuinely missing or incorrect pod routes after successful SSH' {
        Mock Invoke-CmdOnControlPlaneViaSSHKey {
            [pscustomobject]@{ Success = $true; ExitCode = 0; Output = '172.20.1.0/24 via 172.22.1.99' }
        }
        $missing = @(Get-MissingWindowsPodRoutesOnControlPlane -WindowsNodeRoutes $nodeRoutes)
        $missing.Count | Should -Be 1
        $missing[0].PodCIDR | Should -Be '172.20.1.0/24'
    }

    It 'does not attempt transit route replacement when inspection fails' {
        Mock Invoke-CmdOnControlPlaneViaSSHKey {
            [pscustomobject]@{ Success = $false; ExitCode = 255; Output = 'Permission denied (publickey)' }
        }
        { Restore-ControlPlaneTransitRoute } | Should -Throw '*Cannot inspect transit route*Permission denied*'
        Should -Invoke Invoke-CmdOnControlPlaneViaSSHKey -Times 0 -Exactly -ParameterFilter { $CmdToExecute -like 'sudo ip route replace*' }
    }

    It 'leaves a correct transit route untouched' {
        Mock Invoke-CmdOnControlPlaneViaSSHKey {
            [pscustomobject]@{ Success = $true; ExitCode = 0; Output = '172.22.1.0/24 via 172.19.1.1' }
        }
        Restore-ControlPlaneTransitRoute
        Should -Invoke Invoke-CmdOnControlPlaneViaSSHKey -Times 1 -Exactly
    }

    It 'restores a missing transit route after successful inspection' {
        Restore-ControlPlaneTransitRoute
        Should -Invoke Invoke-CmdOnControlPlaneViaSSHKey -Times 1 -Exactly -ParameterFilter {
            $CmdToExecute -eq 'sudo ip route replace 172.22.1.0/24 via 172.19.1.1'
        }
    }

    It 'reports a failed transit route replacement' {
        Mock Invoke-CmdOnControlPlaneViaSSHKey {
            [pscustomobject]@{ Success = $false; ExitCode = 2; Output = 'Network is unreachable' }
        } -ParameterFilter { $CmdToExecute -like 'sudo ip route replace*' }
        { Restore-ControlPlaneTransitRoute } | Should -Throw '*Failed to restore transit route*Network is unreachable*'
    }

    It 'stops flannel repair before restarts when transit inspection fails' {
        Mock Invoke-CmdOnControlPlaneViaSSHKey {
            [pscustomobject]@{ Success = $false; ExitCode = 255; Output = 'Bad permissions' }
        }
        Mock Invoke-KubectlWithKubeConfig {}
        { Restart-FlannelDaemonSetWithWindowsRouteRepair -KubeConfigPath 'C:\k2s\config' } |
            Should -Throw '*Cannot inspect transit route*'
        Should -Invoke Invoke-KubectlWithKubeConfig -Times 0 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'does not start reachability polling when SSH is unavailable' {
        Mock Invoke-CmdOnControlPlaneViaSSHKey {
            [pscustomobject]@{ Success = $false; ExitCode = 255; Output = 'Bad permissions' }
        }
        { Wait-ForControlPlaneTransitReachability -WindowsNodeRoutes $nodeRoutes } |
            Should -Throw '*control-plane SSH failed*Bad permissions*'
        Should -Invoke Invoke-CmdOnControlPlaneViaSSHKey -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'stops polling if SSH fails during a ping' {
        Mock Invoke-CmdOnControlPlaneViaSSHKey {
            [pscustomobject]@{ Success = $false; ExitCode = 255; Output = 'Permission denied' }
        } -ParameterFilter { $CmdToExecute -like 'ping*' }
        { Wait-ForControlPlaneTransitReachability -WindowsNodeRoutes $nodeRoutes } |
            Should -Throw '*SSH or the ping command failed*'
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'retries a real ping reachability failure rather than treating it as an SSH error' {
        $script:pingAttempts = 0
        Mock Invoke-CmdOnControlPlaneViaSSHKey {
            $script:pingAttempts++
            [pscustomobject]@{ Success = ($script:pingAttempts -gt 1); ExitCode = $(if ($script:pingAttempts -eq 1) { 1 } else { 0 }); Output = '' }
        } -ParameterFilter { $CmdToExecute -like 'ping*' }
        Wait-ForControlPlaneTransitReachability -WindowsNodeRoutes $nodeRoutes | Should -BeTrue
        Should -Invoke Start-Sleep -Times 1 -Exactly
    }
}
