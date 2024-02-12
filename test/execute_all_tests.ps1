# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
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
    $ExcludeTags
)
Import-Module "$PSScriptRoot\test.module.psm1" -Force

$pesterVersion = '5.5.0'
$ginkgoVersion = '2.13.2'
$rootDir = "$PSScriptRoot\..\"

Write-Output 'All tests execution started.'

$stopWatch = New-Object -TypeName 'System.Diagnostics.Stopwatch'
$stopWatch.Start()

$currentLocation = Get-Location

$results = @{PowerShell = -1; Go = -1 }

if ($Proxy -ne '') {
    # Set proxy which will be used by tests
    $env:SYSTEM_TEST_PROXY = $Proxy
}

try {
    Install-PesterIfNecessary -Proxy $Proxy -PesterVersion $pesterVersion

    Start-PesterTests -Tags $Tags -ExcludeTags $ExcludeTags -WorkingDir $rootDir -OutDir $TestResultPath -V:$V
    $results.PowerShell = $LASTEXITCODE

    Install-GinkgoIfNecessary -Proxy $Proxy -GinkgoVersion $ginkgoVersion

    Start-GinkgoTests -Tags $Tags -ExcludeTags $ExcludeTags -WorkingDir $rootDir -OutDir $TestResultPath -Proxy $Proxy -V:$V -VV:$VV
    $results.Go = $LASTEXITCODE
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
Write-Output "Test Results are available under '$TestResultPath'"

if ($results.PowerShell -eq 0 -and $results.Go -eq 0) {
    Write-Output '> ALL TESTS PASSED :-)'
    Write-Output '------------------------------------------------'
    return
}

Write-Warning 'TESTS FAILED:'

if ($results.PowerShell -ne 0) {
    Write-Warning '     PowerShell tests :-('
}

if ($results.Go -ne 0) {
    Write-Warning '     Go tests :-('
}

Write-Output '------------------------------------------------'

if ($ThrowOnFailure -eq $true) {
    throw 'Test run failed. See log for details.'
}