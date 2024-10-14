<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
SPDX-License-Identifier: MIT
-->

# Overview
This folder contains all *Go*-based sources bundled into a single *Go* module (`go.mod`).

## Folder structure
```
.
├── cmd         --> contains all Go packages that compile to an application/exe and should only contain application- and command-specific code
├── internal    --> contains re-usable Go packages that cannot be referenced from outside this repo
└── test        --> contains Go-based end-to-end tests/acceptance tests/executable specifications
```
