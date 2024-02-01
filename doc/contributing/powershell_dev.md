<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

# PowerShell Scripts Development
- [PowerShell Scripts Development](#powershell-scripts-development)
- [Automated Testing with Pester](#automated-testing-with-pester)
  - [Install Pester](#install-pester)
  - [Update Pester](#update-pester)
  - [Run Pester](#run-pester)
    - [Code Coverage](#code-coverage)
  - [Tags](#tags)
  - [Logging](#logging)
    - [Dont](#dont)
    - [Do](#do)
  - [Suppress Code Analysis](#suppress-code-analysis)
- [Strings](#strings)
  - [Paths](#paths)
  - [Escaping](#escaping)

---

# Automated Testing with Pester
> For a quick start and command overview, see [Pester Quick Start](https://pester.dev/docs/quick-start).
## Install Pester
[Pester](https://github.com/pester/Pester) comes pre-installed on Win 10 or later.

To check the installed version, run:
```PowerShell
PS> Import-Module Pester -Passthru
```

This output will be similar to:
```
ModuleType Version    Name                                ExportedCommands
---------- -------    ----                                ----------------
Script     3.4.0      Pester                              {AfterAll, AfterEach, Assert-MockCalled, Assert-VerifiableMocks...}
```
> It is highly recommended to update Pester to the latest version to have a consistent set of test APIs.
## Update Pester
If Pester was not installed explicitly yet (i.e., the version shipped with Windows is installed), run:
```PowerShell
PS> Install-Module Pester -Force -SkipPublisherCheck
```

For subsequent updates, run:
```PowerShell
PS> Update-Module -Name Pester
```

To check the version, see [Install Pester](#install-pester).

## Run Pester
To start test discovery and execution, run:
```PowerShell
PS> Invoke-Pester .\<test file>.tests.ps1
```
> Pester discovers test files via naming convention **\*.\[T|t\]ests.ps1**

To see detailed output, run:
```PowerShell
PS> Invoke-Pester -Output Detailed .\<test file>.Tests.ps1
```
To include/exclude tests by tags, run:
```PowerShell
PS> Invoke-Pester -Tag "acceptance" -ExcludeTag "slow", "linuxOnly" .\<test file>.Tests.ps1
```

### Code Coverage
To calculate the code coverage of a test run, additionally specify the file(s) under test:
```PowerShell
PS> Invoke-Pester .\<test file>.Tests.ps1 -CodeCoverage .\<file-under-test>.ps1
```

To export the code coverage results as [JaCoCo](https://www.jacoco.org/) XML file, specify the output file:
```PowerShell
PS> Invoke-Pester .\<test file>.Tests.ps1 -CodeCoverage .\<file-under-test>.ps1 -CodeCoverageOutputFile <some dir>\coverage.xml
```

See [Pester Code Coverage](https://pester.dev/docs/usage/code-coverage/) for more options.

## Tags
See [Tags/Labels](./Contributing.md#tagslabels).

## Logging
When executing K2s scripts inside Pester test functions, it is recommended to execute these scripts in a separate PowerShell session, so that the called scripts still log to the K2s log files due to the current logging implementation.

### Dont
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

### Do
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

## Suppress Code Analysis
*Pester* requires a certain test code structure that can lead to code analyzer warnings, e.g. in this case:
```PowerShell
BeforeAll {
    $module = "$PSScriptRoot\setupinfo.module.psm1"

    $moduleName = (Import-Module $module -PassThru -Force).Name
}
```
The analyzer would complain:
> The variable 'moduleName' is assigned but never used. *PSScriptAnalyzer(PSUseDeclaredVarsMoreThanAssignments)*

To mitigate this, suppress this warning like the following:
```PowerShell
BeforeAll {
    $module = "$PSScriptRoot\setupinfo.module.psm1"

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
    $moduleName = (Import-Module $module -PassThru -Force).Name
}
```

# Strings
PowerShell takes us a lot of thinking off when it comes to strings.

For example just using 
```PowerShell 
$myPath\theFile.yaml
```
will be interpreted as a string in the end. \
When using double quotes like 
```PowerShell 
"$myPath\theFile.yaml"
```
we are then telling PowerShell that it is a string (PowerShell doesn't have to do its best guess).\
And if our string must contain double quotes, then 
```PowerShell 
"`"$myPath\theFile.yaml`""
```
(in the latter case, PowerShell interprets a string out of it) has to be used.

## Paths
Since a path can contain empty spaces extra attention has to be paid, specially when calling an external Windows tool with a path as argument.

The rule of thumb is the following:

- If a path value is used as argument in a call to an external tool --> add double quotes to the path value
```PowerShell
    e.g.:  &$global:BinPath\kubectl.exe delete -f "$myPath\theFile.yaml"
```
- else --> nothing to do, PowerShell takes care of it

For some tools this is not strictly necessary, but doing so we are on the safe side, it proves that we have reflected on this and also helps the
next developer that is confronted with the code (many times just ourselves...)

## Escaping

Escaping has been changed in Powershell Core (PS version > 5) which is required for multi-vm setup. The following example shows how quotes needs to be escaped when executing a linux remote command:

```Powershell
if ($PSVersionTable.PSVersion.Major -gt 5) {
    ExecCmdMaster "echo Acquire::http::Proxy \""$Proxy\""\; | sudo tee -a /etc/apt/apt.conf.d/proxy.conf" -UsePwd
} else {
    ExecCmdMaster "echo Acquire::http::Proxy \\\""$Proxy\\\""\; | sudo tee -a /etc/apt/apt.conf.d/proxy.conf" -UsePwd
}
```