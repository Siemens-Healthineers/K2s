<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
SPDX-License-Identifier: MIT
-->

# Automated Testing
## Automate Everything
The ultimate goal is to automate every test case and type, i.e.:

- Unit tests
- Integration Tests
- e2e tests / system tests / acceptance tests / executable specifications (BDD)

!!! info
    Acceptance tests might require a running *K2s* cluster.

## Prerequisites
[Install *Pester*](#install-pester) and [Install *Ginkgo*](https://onsi.github.io/ginkgo/#installing-ginkgo){target="_blank"}.

!!! tip
    When running the [Main Script: execute_all_tests.ps1](#main-script-execute_all_testsps1) for the first time, those prerequisites are installed automatically in the correct version.
  
## Main Script: execute_all_tests.ps1
The main entry point for automated testing is the script `execute_all_tests.ps1`, whether being executed locally or in CI/CD workflows. It is not mandatory, but recommended to use this script instead of running *Pester* or *Ginkgo* commands directly due to the following features of the `execute_all_tests.ps1` script:

- Run all test suites in this repository (*PowerShell*- or *Go*-based tests)
- Automatic installation of the required testing frameworks on-the-fly when they do not exist in the required version (i.e. *Pester* and *Ginkgo*)
- Tags/labels filtering that applies both to *PowerShell* and *Go*
- Options to exclude either *PowerShell* or *Go* tests
- Unified test execution report

!!! example
    ```powershell
    <repo>\test\execute_all_tests.ps1 -Tags unit -ExcludeGoTests
    ```

The preceding example would execute all *PowerShell*-based tests tagged with `unit`.

!!! tip
    Inspect the [execute_all_tests.ps1](https://github.com/Siemens-Healthineers/K2s/blob/main/test/execute_all_tests.ps1){target="_blank"} script for further parameter details and descriptions.<br/>
    See [Commonly Used Tags](tags-labels.md#commonly-used-tags) for commonly used labels/tags.
    
## Automated Testing with Pester
!!! note
    For a quick start and command overview, see [Pester Quick Start](https://pester.dev/docs/quick-start){target="_blank"}.
### Install Pester
!!! info
    [Pester](https://github.com/pester/Pester){target="_blank"} comes pre-installed on Win 10 or later.

To check the installed version, run:
```PowerShell
Import-Module Pester -Passthru
```

This output will be similar to:
``` title="Output"
ModuleType Version    Name    ExportedCommands
---------- -------    ----    ----------------
Script     3.4.0      Pester  {AfterAll, AfterEach, Assert-MockCalled, Assert-VerifiableMocks...}
```
!!! tip
    It is highly recommended to update Pester to the latest version to have a consistent set of test APIs.
 
### Update Pester
If Pester was not installed explicitly yet (i.e., the version shipped with Windows is installed), run:
```PowerShell
Install-Module Pester -Force -SkipPublisherCheck
```

For subsequent updates, run:
```PowerShell
Update-Module -Name Pester
```

### Run Pester
To start test discovery and execution, run:
```PowerShell
Invoke-Pester .\<test file>.tests.ps1
```
!!! info
    Pester discovers test files via naming convention **\*.\[T|t\]ests.ps1**

To see detailed output, run:
```PowerShell
Invoke-Pester -Output Detailed .\<test file>.Tests.ps1
```
To include/exclude tests by tags, run:
```PowerShell
Invoke-Pester -Tag "acceptance" -ExcludeTag "slow", "linuxOnly" .\<test file>.Tests.ps1
```

#### Code Coverage
To calculate the code coverage of a test run, additionally specify the file(s) under test:
```PowerShell
Invoke-Pester .\<test file>.Tests.ps1 -CodeCoverage .\<file-under-test>.ps1
```

To export the code coverage results as [JaCoCo](https://www.jacoco.org/){target="_blank"} XML file, specify the output file:
```PowerShell
Invoke-Pester .\<test file>.Tests.ps1 -CodeCoverage .\<file-under-test>.ps1 -CodeCoverageOutputFile <some dir>\coverage.xml
```

!!! note
    See [Pester Code Coverage](https://pester.dev/docs/usage/code-coverage/){target="_blank"} for more options.

### Log Output Redirection
When executing *K2s* scripts inside *Pester* test functions, it is recommended to execute these scripts in a separate *PowerShell* session, so that the called scripts still log to the *K2s* log files due to the current logging implementation.

#### Don't
```PowerShell
# ...
$enableScript = "$PSScriptRoot\Enable.ps1"
# ...
It 'does not log to log file :-(' {
    $output = $(&$enableScript -ShowLogs) *>&1 # output redirect, but no log file entries
    # ...
}
# ...
```

#### Do
```PowerShell
# ...
$enableScript = "$PSScriptRoot\Enable.ps1"
# ...
It 'logs to log file :-)' {
    $output = powershell -Command "$enableScript -ShowLogs" *>&1 # output redirect and log file entries
    # ...
}
# ...
```

### Suppress Code Analysis
*Pester* requires a certain test code structure that can lead to code analyzer warnings, e.g. in this case:
```PowerShell
BeforeAll {
    $module = "$PSScriptRoot\setupinfo.module.psm1"

    $moduleName = (Import-Module $module -PassThru -Force).Name
}
```
The analyzer would complain:
!!! quote
    The variable 'moduleName' is assigned but never used. *PSScriptAnalyzer(PSUseDeclaredVarsMoreThanAssignments)*

To mitigate this, suppress this warning like the following:
```PowerShell
BeforeAll {
    $module = "$PSScriptRoot\setupinfo.module.psm1"

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
    $moduleName = (Import-Module $module -PassThru -Force).Name
}
```

## Automated Testing with Ginkgo/Gomega
### Log Output Redirection
For diagnostic logging, *k2s* CLI uses [slog](https://pkg.go.dev/log/slog){target="_blank"}. To redirect the log output to *Ginkgo*, set the *Ginkgo* logger as follows (*Ginkgo* uses [logr](https://github.com/go-logr/logr/){target="_blank"} internally):
```go
var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})
```

This enables control over *slog* output, i.e. the output can be enabled when running *Ginkgo* in verbose mode (`ginkog -v`) and be omitted in non-verbose mode.