<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

# Contributor License Agreement
There are two versions of the Contributor License Agreement (CLA). 
The contributor should be able to chose the right one: 

* contribution by an individual [CLA Individual Contributor](./CLA-IndividualContributor.md) 
* contribution by his/her employer (typically a legal entity) [CLA Corporate Contributor](./CLA-CorporateContributor.md).

The CLA is drafted for re-use for any contributions the (same) contributor makes, so that it needs to be signed only once.
This CLA does not enable Siemens Healthineers to use or process personal data. The contributor must not contribute personal data according to this CLA.

# Contributing with code
- [Contributor License Agreement](#contributor-license-agreement)
- [Contributing with code](#contributing-with-code)
  - [Clone *Git* Repository](#clone-git-repository)
  - [Codebase Structure](#codebase-structure)
  - [Building Locally](#building-locally)
    - [Workspace Prerequisites](#workspace-prerequisites)
    - [Build *Go* projects](#build-go-projects)
  - [Testing](#testing)
    - [Tags/Labels](#tagslabels)
      - [*Pester* Example](#pester-example)
      - [*Ginkgo* Example](#ginkgo-example)
      - [Commonly Used Tags](#commonly-used-tags)
    - [Log Output Redirection](#log-output-redirection)

---

The code is mainly written in *Go* and *PowerShell*. See [*PowerShell* Scripts Development](powershell_dev.md) for more information about *PowerShell* development.

## Clone *Git* Repository

```shell
> mkdir c:\myFolder; cd c:\myFolder
C:\myFolder> git clone https://github.com/Siemens-Healthineers/K2s .
```


## Codebase Structure
<pre>
├── addons
├── bin
├── build
├── cfg         --> Configuration files
├── doc
├── LICENSES
└── pkg         --> Go based projects
    ├── base
    ├── network
    ├── k2s
    └── util
├── smallsetup  --> PowerShell scripts
├── test
├── README.md
├── k2s.exe
└── VERSION
</pre>

## Building Locally

### Workspace Prerequisites

All the prerequisites mentioned in [Install Prerequisites](../k2scli/install-uninstall_cmd.md#installing) are necessary.

* Install [*Go*](https://go.dev/dl/) for *Windows*.

### Build *Go* projects

Building *Go* based projects is done through [BuildGoExe.ps1](../../smallsetup/common/BuildGoExe.ps1)

> `bgo.cmd` is a shortcut command to invoke script BuildGoExe.ps1.

If you have not installed *K2s* yet, then your PATH is not updated with required locations. In this case, look for bgo.cmd and invoke the build command. In the below example, `c:\k` is the root of our *Git* repo.

```PowerShell
PS> where.exe bgo
C:\k\bin\bgo.cmd
```

Building `httpproxy` *Go* project:

```PowerShell
PS> C:\k\bin\bgo -ProjectDir "C:\k\pkg\network\httpproxy\" -ExeOutDir "c:\k\bin"
```

 <span style="color:orange;font-size:medium">**💡**</span> `k2s` CLI can be built without any parameters:
```PowerShell
PS> C:\k\bin\bgo
```

To build all *Go* executables:
```PowerShell
PS> C:\k\bin\bgo -BuildAll 1
```

If *K2s* is installed then just simply execute command without full path.
```PowerShell
PS> bgo -ProjectDir "C:\k\pkg\network\httpproxy\" -ExeOutDir "c:\k\bin"
PS> bgo -BuildAll 1
```
---
## Testing 

<span style="color:orange;font-size:medium">**⚠** </span> Prerequisites: [Install *Pester*](powershell_dev.md#install-pester) and [Install *Ginkgo*](https://onsi.github.io/ginkgo/#installing-ginkgo).

When you have made changes either to PowerShell scripts or Go projects, you can run all test suites in the repository via:

```PowerShell
PS> c:\k\test\execute_all_tests.ps1
```
<span style="color:orange;font-size:medium">**⚠** </span> Acceptance/e2e/system tests might require a running *K2s* cluster. See also [*K2s* Acceptance Testing](../../test/README.md).

To filter tests for e.g. executing only unit tests, use the **-Tags** and **-ExcludeTags** parameters:
```PowerShell
PS> c:\k\test\execute_all_tests.ps1 -Tags unit
```

> Inspect the script for further parameter details and descriptions.

### Tags/Labels
To control which tests or test types shall be executed in which context/environment, tags/labels can be utilized.
> See [*Pester* Tag Documentation](https://pester.dev/docs/usage/tags) for information about tagging/labelling Pester tests.<br/>
> See [*Ginkgo* Spec Labels Documentation](https://onsi.github.io/ginkgo/#spec-labels) for information about tagging/labelling Ginkgo tests.

#### *Pester* Example
Define one or more tags at any level of a test container:
```PowerShell
Describe 'Get-Status' -Tag 'unit', 'addon' {
    # ...
}
```
Execute tests with tag *unit*:
```sh
PS> Invoke-Pester <dir-with-test-files> -Tag unit
```

#### *Ginkgo* Example
Define one or more tags at any level of a test node, here for a whole test suite:
```Go
// ...
func TestHttpproxyUnitTests(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "httpproxy Unit Tests", Label("unit"))
}
// ...
```
Execute tests with tag *unit*:
```sh
PS> ginkgo --label-filter="unit" <dir-with-test-suites>
```

#### Commonly Used Tags
| Name                     | Description                                                                                                                |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------- |
| **acceptance**           | end-to-end test/executable spec in production-like scenario                                                                |
| **integration**          | test requiring certain external resources/systems to be reachable or additional software to be installed                   |
| **unit**                 | test can be executed in isolation, all dependencies to the environment are mocked                                          |
| **addon**                | test is addon-related and does not test *K2s* core functionality                                                           |
| **internet-required**    | test requires internet connectivity, e.g. for package downloads                                                            |
| **invasive**             | test changes either state of the host system or *K2s* installation                                                         |
| **read-only**            | test does not change state of the host system or *K2s* installation; optional, since read-only tests should be the default |
| **setup-required**       | test requires *K2s* to be installed; currently, the tests determine the setup type in the test runs                        |
| **no-setup**             | *K2s* must not be installed on the system to test pre-installation behavior                                                |
| **setup=\<setup name\>** | *K2s* setup type must match, e.g. *setup=k2s* or *setup=MultiVMK8s*                                                        |
| **system-running**       | test requires *K2s* to be started/running                                                                                  |
| **system-stopped**       | test requires *K2s* to be stopped                                                                                          |

### Log Output Redirection
For diagnostic logging, *k2s* CLI uses the [klog](https://pkg.go.dev/k8s.io/klog/v2#section-readme) module. To redirect the log output to *Ginkgo*, set the *Ginkgo* logger as follows:

```go
var _ = BeforeSuite(func() {
	klog.SetLogger(GinkgoLogr)
})
```

This enables control over *klog* output, i.e. the output can be enabled when running *Ginkgo* in verbose mode (`ginkog -v`) and be omitted in non-verbose mode.