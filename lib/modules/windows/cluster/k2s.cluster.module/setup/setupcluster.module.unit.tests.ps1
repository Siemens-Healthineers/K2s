# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

Describe 'Wait-KubeadmJoinProcess' -Tag 'unit', 'ci', 'cluster' {
BeforeAll {
    $modulePath = "$PSScriptRoot/setupcluster.module.psm1"
    $parseErrors = $null
    $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) { throw ($parseErrors | Out-String) }
    $waitFunction = $moduleAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Wait-KubeadmJoinProcess'
    }, $false)
    . ([scriptblock]::Create($waitFunction.Extent.Text))

    $script:kubeToolsPath = 'C:\k'
    function Write-Log { param($Message, [switch]$Console) }
    function Stop-Process { [CmdletBinding()] param($Id, [switch]$Force) }
    function Get-Service { [CmdletBinding()] param($Name) }
}

    BeforeEach {
        Mock Write-Log {}
        Mock Stop-Process {}
        Mock Get-Service {}
    }

    It 'returns the process exit code when kubeadm finishes in time' {
        $process = [pscustomobject]@{
            Handle = [intptr]::Zero
            Id = 42
            ExitCode = 0
        }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($milliseconds) return $true }

        $result = Wait-KubeadmJoinProcess -Process $process -StandardOutputPath 'missing.stdout' -StandardErrorPath 'missing.stderr'

        $result | Should -Be 0
        Should -Invoke Stop-Process -Times 0 -Exactly
    }

    It 'terminates only the timed-out kubeadm process and throws' {
        $process = [pscustomobject]@{
            Handle = [intptr]::Zero
            Id = 73
            ExitCode = -1
        }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
            param($milliseconds)
            if ($null -eq $milliseconds) { return }
            return $false
        }

        {
            Wait-KubeadmJoinProcess -Process $process -StandardOutputPath 'missing.stdout' `
                -StandardErrorPath 'missing.stderr' -TimeoutSeconds 1
        } | Should -Throw '*timed out after 1 seconds*'

        Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 73 -and $Force }
    }
}
