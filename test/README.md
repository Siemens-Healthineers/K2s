<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
SPDX-License-Identifier: MIT
-->

# Overview
This folder contains test scripts to execute *Go*-based as well as *PowerShell*-based automated tests.

Test types are:
- Unit tests
- Integration Tests
- End-to-end tests / acceptance tests / executable specifications

The scripts will install the required testing frameworks on-the-fly when they do not exist in the required version.

## Executing Tests
The main entry point is the script `execute_all_tests.ps1`.

### Example Usage
Run:
```powershell
.\execute_all_tests.ps1 -Tags unit -ExcludeGoTests
```

The preceding example would execute all *PowerShell*-based tests labelled/tagged with `unit`.

> See [execute_all_tests.ps1](execute_all_tests.ps1) for a documentation of all available parameters or [Commonly Used Tags](../doc/contributing/CONTRIBUTING.md#commonly-used-tags) for commonly used labels/tags.