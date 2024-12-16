# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Executes all configured tests
.DESCRIPTION
Executes all configured PowerShell and Go-based tests sequentially
.PARAMETER V
    Verbose output
.PARAMETER VV
    Super-verbose output for diagnosing the test script
.PARAMETER ThrowOnFailure
    Throws an exception after all tests were executed when a test failed
.PARAMETER Tags
    List of tags to include in test runs; test matches if at least one include tag matches
.PARAMETER ExcludeTags
    List of tags to exclude from test runs; test matches if none of the exclude tags match
.NOTES
    Requires a running K2s K8s cluster if acceptance tests are about to be executed
.EXAMPLE
    $> .\test\execute_all_tests.ps1
    Execute all tests
.EXAMPLE
    $> .\test\execute_all_tests.ps1 -V
    Execute all tests with verbose output
.EXAMPLE
    $> .\test\execute_all_tests.ps1 -Tags "unit"
    Execute only tests marked as unit tests
.EXAMPLE
    $> .\test\execute_all_tests.ps1 -Tags "acceptance"
    Execute only tests marked as acceptance tests
.EXAMPLE
    $> .\test\execute_all_tests.ps1 -ExcludeTags "setup-required"
    Exclude tests marked as requiring an installed K2s system
.EXAMPLE
    $> .\test\execute_all_tests.ps1 -ExcludePowershellTests
    Execute only Go tests and exclude Powershell tests
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [switch]
    $V = $false,
    [Parameter(Mandatory = $false)]
    [switch]
    $VV = $false,
    [Parameter(Mandatory = $false)]
    [switch]
    $ThrowOnFailure = $false,
    [Parameter(Mandatory = $false, HelpMessage = 'Will be used only to download go modules for testing')]
    [string]
    $Proxy,
    [Parameter(Mandatory = $false, HelpMessage = 'Directory under which powershell and Go test results should be dumped')]
    [string]
    $TestResultPath = "$env:temp\k2s-test-results",
    [Parameter(Mandatory = $false, HelpMessage = 'List of tags to include in test runs')]
    [string[]]
    $Tags,
    [Parameter(Mandatory = $false, HelpMessage = 'List of tags to exclude from test runs')]
    [string[]]
    $ExcludeTags,
    [Parameter(Mandatory = $false, HelpMessage = 'Exclude Powershell/Pester tests')]
    [switch]
    $ExcludePowershellTests,
    [Parameter(Mandatory = $false, HelpMessage = 'Exclude Go/Ginkgo tests')]
    [switch]
    $ExcludeGoTests,
    [Parameter(Mandatory = $false, HelpMessage = 'Indicates system test running in offline mode and all internet based tests can be skipped with this')]
    [switch]
    $OfflineMode

)

if ($ExcludePowershellTests -and $ExcludeGoTests) {
    Write-Output 'Skipping Powershell and Go tests. Nothing to tests.'
    return
}

Import-Module "$PSScriptRoot\test.module.psm1" -Force

$pesterVersion = '5.6.1'
$ginkgoVersion = '2.20.2'
$rootDir = "$PSScriptRoot\..\"

# switch to drive
$drive = Split-Path -Path $rootDir -Qualifier
&$drive

Write-Output 'All tests execution started.'

$stopWatch = New-Object -TypeName 'System.Diagnostics.Stopwatch'
$stopWatch.Start()

$currentLocation = Get-Location

$results = @{PowerShell = -1; Go = -1 }

if ($Proxy -ne '') {
    # Set proxy which will be used by tests
    $env:SYSTEM_TEST_PROXY = $Proxy
}

if ($OfflineMode) {
    # Set proxy which will be used by tests
    Write-Output 'Set to System Test Offline mode'
    $env:SYSTEM_OFFLINE_MODE = $true
}
else {
    $env:SYSTEM_OFFLINE_MODE = $false
}

try {
    if (!$ExcludePowershellTests) {
        Install-PesterIfNecessary -Proxy $Proxy -PesterVersion $pesterVersion

        Start-PesterTests -Tags $Tags -ExcludeTags $ExcludeTags -WorkingDir $rootDir -OutDir $TestResultPath -V:$V
        $results.PowerShell = $LASTEXITCODE
    }
    else {
        Write-Output 'Skipping Powershell tests'
    }

    if (!$ExcludeGoTests) {
        Install-GinkgoIfNecessary -Proxy $Proxy -GinkgoVersion $ginkgoVersion

        $goSrcDir = [System.IO.Path]::Combine($rootDir, 'k2s')

        Start-GinkgoTests -Tags $Tags -ExcludeTags $ExcludeTags -WorkingDir $goSrcDir -OutDir $TestResultPath -Proxy $Proxy -V:$V -VV:$VV
        $results.Go = $LASTEXITCODE
    }
    else {
        Write-Output 'Skipping Go tests'
    }
}
catch {
    # re-throw to stop execution also in case of dynamic exceptions, e.g. ParameterBindingValidationException
    throw $_
}

$stopWatch.Stop()

Write-Output "All tests execution finished after $($stopWatch.ElapsedMilliseconds/1000)s."
Write-Output ''
Write-Output '------------------------------------------------'

Set-Location $currentLocation
Write-Output "Test Results are available under '$TestResultPath'`n"

if ($results.Go -eq 197) {
    Write-Warning "Ginkgo detected Programmatic Focus - was setting exit status to '197'. Resetting to '0'."
    $results.Go = 0
}

if ($results.PowerShell -eq 0 -and $results.Go -eq 0) {
    Write-Output '> ALL TESTS PASSED :-)'
    Write-Output '------------------------------------------------'
    return
}

if ($results.PowerShell -eq 0 -and $results.Go -eq -1) {
    Write-Output '> GO TESTS SKIPPED :-)'
    Write-Output '> ALL POWERSHELL TESTS PASSED :-)'
    Write-Output '------------------------------------------------'
    return
}

if ($results.PowerShell -eq -1 -and $results.Go -eq 0) {
    Write-Output '> POWERSHELL TESTS SKIPPED :-)'
    Write-Output '> ALL GO TESTS PASSED :-)'
    Write-Output '------------------------------------------------'
    return
}

Write-Warning 'TESTS FAILED:'

if ($results.PowerShell -ne 0 -and $results.PowerShell -ne -1) {
    Write-Warning '     PowerShell tests :-('
}

if ($results.Go -ne 0 -and $results.Go -ne -1) {
    Write-Warning '     Go tests :-('
}

Write-Output '------------------------------------------------'

if ($ThrowOnFailure -eq $true) {
    throw 'Test run failed. See log for details.'
}