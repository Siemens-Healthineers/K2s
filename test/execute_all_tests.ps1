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
    $> .\test\execute_all_tests.ps1 -Tags "acceptance", "addon"
    Execute only tests marked as acceptance tests for addons
.EXAMPLE
    $> .\test\execute_all_tests.ps1 -ExcludeTags "setup-required"
    Exclude tests marked as requiring an installed K2s
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [switch]
    $V = $false,
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
$pesterVersion = '5.5.0'
$ginkgoVersion = '2.13.2'

function ExecuteCommandWithPowershell([string]$Command)
{
    $powershellExe = "powershell.exe"
    $arguments = "-noprofile -Command `"$Command`""
	Write-Host "Calling $powershellExe $arguments"
	try{
		$startInfo = New-Object System.Diagnostics.ProcessStartInfo
		$startInfo.FileName = $powershellExe
		$startInfo.RedirectStandardError = $true
		$startInfo.RedirectStandardOutput = $true
		$startInfo.UseShellExecute = $false
		$startInfo.Arguments = $arguments
		$process = New-Object System.Diagnostics.Process
		$process.StartInfo = $startInfo
        # Register Object Events for stdin\stdout reading
		$OutEvent = Register-ObjectEvent -Action {
		    Write-Host $Event.SourceEventArgs.Data
		} -InputObject $process -EventName OutputDataReceived
		$ErrEvent = Register-ObjectEvent -Action {
		    Write-Host $Event.SourceEventArgs.Data
		} -InputObject $process -EventName ErrorDataReceived
		$process.Start() | Out-Null
		$process.BeginOutputReadLine()
		$process.BeginErrorReadLine()
		$process.WaitForExit()
        # Unregister events
		$OutEvent.Name, $ErrEvent.Name |
        ForEach-Object {Unregister-Event -SourceIdentifier $_}
		$exitCode = $process.ExitCode
		return $exitCode
	}
	finally
	{
		if($null -ne $process)
		{
			$process.Dispose()
		}
    }
}

function ExecuteGoCommand {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Proxy,
        [Parameter(Mandatory = $false)]
        [string]
        $Cmd
    )

    $currentHttpProxy = $env:http_proxy
    $currentHttpsProxy = $env:https_proxy

    try {
        $env:http_proxy = $Proxy
        $env:https_proxy = $Proxy
        $exitCode = ExecuteCommandWithPowershell -Command $Cmd
        if ($exitCode -ne 0) {
            $errorMessage = "Command $cmd resulted in a non-zero exit code. Exit Code: $exitCode"
            throw $errorMessage
        }
    }
    finally {
        $env:http_proxy = $currentHttpProxy
        $env:https_proxy = $currentHttpsProxy
    }
}

function EnsureGinkgoInstalled {
    $ginkgoCmd = Get-Command -ErrorAction Ignore -Type Application ginkgo

    if (!$ginkgoCmd) {
        Write-Output 'Ginkgo not found, installing it..'
        ExecuteGoCommand -Proxy $Proxy -Cmd "go.exe install 'github.com/onsi/ginkgo/v2/ginkgo@v$ginkgoVersion'"
    }

    $foundVersion = (ginkgo.exe version).Split(' ')[2].Trim()

    Write-Output "Found Ginkgo version $foundVersion"

    if ($foundVersion -ne $ginkgoVersion) {
        Write-Output "Updating Ginkgo to version $ginkgoVersion.."
        ExecuteGoCommand -Proxy $Proxy -Cmd "go.exe install 'github.com/onsi/ginkgo/v2/ginkgo@v$ginkgoVersion'"
    }
}

function EnsurePesterIsInstalled {
    $pesterModule = Get-InstalledModule -Name Pester

    if (!$pesterModule) {
        Write-Output 'Pester not found, installing it..'

        $pkgProviderVersion = '2.8.5.201 '

        if ($Proxy -ne '') {
            Install-PackageProvider -Name NuGet -MinimumVersion $pkgProviderVersion -Force -Proxy $Proxy
            Register-PSRepository -Default -Proxy $Proxy -ErrorAction SilentlyContinue
            Install-Module -Name Pester -Proxy $Proxy -Force -SkipPublisherCheck -MinimumVersion $pesterVersion
        }
        else {
            Install-PackageProvider -Name NuGet -MinimumVersion $pkgProviderVersion -Force
            Register-PSRepository -Default -ErrorAction SilentlyContinue
            Install-Module -Name Pester -Force -SkipPublisherCheck -MinimumVersion $pesterVersion
        }
        return
    }
    
    $foundVersion = "$($pesterModule.Version.Major).$($pesterModule.Version.Minor).$($pesterModule.Version.Build)"
    
    Write-Output "Found Pester version $foundVersion"
    
    if ($foundVersion -ne $pesterVersion) {
        Write-Output "Updating Pester to version $pesterVersion.."

        Update-Module -Name Pester -RequiredVersion $pesterVersion -Force
    }
}

function Start-GoTests {
    param (
        [Parameter(Mandatory = $false)]
        [string[]]
        $Tags,
        [Parameter(Mandatory = $false)]
        [string[]]
        $ExcludeTags,
        [Parameter(Mandatory = $false)]
        [string]
        $WorkingDir = (throw 'working directory not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $Proxy
    )
    Write-Output "Executing Go tests in '$WorkingDir' with verbose='$V' for tags '$Tags' and excluding tags '$ExcludeTags'..."

    if ($Proxy -ne '') {
        Write-Output "Using Proxy to download go modules: '$Proxy'..."
        ExecuteGoCommand -Proxy $Proxy -Cmd "cd $WorkingDir;ls;go.exe mod download"
    }

    $goCommand = 'ginkgo'
    if ($V -eq $true) {
        $goCommand += ' -v'
    }

    #$goCommand += ' -r' # recursive, equivalent to './...'
    $goCommand += ' --require-suite' # complains about specs without test suite
    $goCommand += " --junit-report=GoTest-$((Get-Date -Format 'yyyy-MM-dd-HH-mm-ss').ToString()).xml"
    $goCommand += " --output-dir=$TestResultPath"

    if ($null -ne $Tags -or $null -ne $ExcludeTags) {
        # see https://onsi.github.io/ginkgo/#filtering-specs
        $goCommand += ' --label-filter="'
        $isFirstLabel = $true

        foreach ($tag in $Tags) {
            if ($isFirstLabel -eq $true) {
                $isFirstLabel = $false
            }
            else {
                $goCommand += ' || '
            }

            $goCommand += $tag
        }

        foreach ($tag in $ExcludeTags) {
            if ($isFirstLabel -eq $true) {
                $isFirstLabel = $false
            }
            else {
                $goCommand += ' && '
            }

            $goCommand += "!$tag"
        }

        $goCommand += '"'
    }

    Write-Output "Executing Gingko Command: '$goCommand'"

    $folders = Get-ChildItem -Path "$WorkingDir" -Directory -Recurse
    $errorOccured = $false
    $gingkoLabelCmd = 'ginkgo labels 2>&1'

    # Iterate through each folder and run the Ginkgo command for matched label
    foreach ($folder in $folders) {
        if ($errorOccured) {
            Write-Output 'Error occured during test execution'
            break
        }
        Set-Location -Path $folder.FullName


        # Check for any labels before executing
        $labelsFound = Invoke-Expression $gingkoLabelCmd
        foreach ($tag in $Tags) {
            if ($labelsFound -match $tag) {
                # Run the Ginkgo command
                Invoke-Expression $goCommand | Tee-Object -Variable result
                if ($result -match '\[FAIL\]' -or $result -match 'Test Suite Failed') {
                    $errorOccured = $true
                }
                break
            }
        }
    }

    if (!$errorOccured) {
        # If no errors then simulate success exit code
        cmd.exe /c hostname 2>&1 | Out-Null
    }
}

function Start-PowerShellTests {
    param (
        [Parameter(Mandatory = $false)]
        [string[]]
        $Tags,
        [Parameter(Mandatory = $false)]
        [string[]]
        $ExcludeTags,
        [Parameter(Mandatory = $false)]
        [string]
        $WorkingDir = (throw 'working directory not specified'),
        [Parameter(Mandatory = $false)]
        [ValidateSet('None', 'Run', 'Container', 'Block')]
        [string]
        $SkipRemainingOnFailure = 'None'
    )
    Write-Output "Executing Powershell tests in '$WorkingDir' with verbose='$V' for tags '$Tags' and excluding tags '$ExcludeTags'..."

    $pesterConf = New-PesterConfiguration
    $pesterConf.Run.Path = "$WorkingDir"
    $pesterConf.Run.SkipRemainingOnFailure = $SkipRemainingOnFailure
    $pesterConf.Filter.Tag = $Tags
    $pesterConf.Filter.ExcludeTag = $ExcludeTags
    $pesterConf.TestResult.Enabled = $true
    $pesterConf.TestResult.OutputPath = $TestResultPath + '\PowershellTest-' + (Get-Date -Format 'yyyy-MM-dd-HH-mm-ss').ToString() + '.xml'

    if ($V -eq $true) {
        $pesterConf.Output.Verbosity = 'Detailed'
    }

    Invoke-Pester -Configuration $pesterConf
}

Write-Output 'All tests execution started.'

$currentLocation = Get-Location

$results = @{PowerShell = -1; Go = -1 }

if ($Proxy -ne '') {
    # Set proxy which will be used by tests
    $env:SYSTEM_TEST_PROXY = $Proxy
}

try {
    EnsurePesterIsInstalled

    Start-PowerShellTests -Tags $Tags -ExcludeTags $ExcludeTags -WorkingDir $PSScriptRoot\..\
    $results.PowerShell = $LASTEXITCODE

    EnsureGinkgoInstalled

    Start-GoTests -Tags $Tags -ExcludeTags $ExcludeTags -WorkingDir $PSScriptRoot\..\ -Proxy $Proxy
    $results.Go = $LASTEXITCODE
}
catch {
    # re-throw to stop execution also in case of dynamic exceptions, e.g. ParameterBindingValidationException
    throw $_
}

Write-Output 'All tests execution finished.'
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