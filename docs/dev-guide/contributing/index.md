<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
SPDX-License-Identifier: MIT
-->

# Contributing
## Contributor License Agreement
There are two versions of the Contributor License Agreement (CLA). 
The contributor should be able to chose the right one: 

* contribution by his/her employer (typically a legal entity) [CLA Corporate Contributor](./cla-corporate-contributor.md)
* contribution by an individual [CLA Individual Contributor](./cla-individual-contributor.md) 

The CLA is drafted for re-use for any contributions the (same) contributor makes, so that it needs to be signed only once.
This CLA does not enable Siemens Healthineers to use or process personal data. The contributor must not contribute personal data according to this CLA.

## Contributing with code
The code is mainly written in *Go* and *PowerShell*. See [*PowerShell* Development](powershell-dev.md) for more information.

The codebase structure looks like the following:

```{.text .no-copy title=""}
├── addons      --> Addon(s)-specific configuration and PowerShell scripts
├── bin         --> Binaries (either committed to this repo or dropped as build target)
├── build
├── cfg         --> Configuration files
├── docs        --> Main documentation
├── k2s         --> Go-based sources
├── lib         --> PowerShell scripts
├── LICENSES
├── smallsetup  --> [legacy] PowerShell scripts; to be migrated to "lib"
├── test        --> Main test script(s)
├── ...
├── README.md
├── k2s.exe
├── VERSION
└── ...
```

1. [Clone the *Git* Repository](../../op-manual/getting-k2s.md#option-2-cloning-git-repository)
2. Make your changes locally, adhering to the [Licensing Obligations](licensing.md)
3. [Build Locally](building-locally.md)
4. Create [Automated Tests](automated-testing.md) and execute them successfully
5. [Update the Documentation](updating-documentation.md)
6. [Submit your Changes](submitting-changes.md)