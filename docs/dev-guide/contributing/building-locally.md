<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
SPDX-License-Identifier: MIT
-->

# Building Locally
## Workspace Prerequisites
All the prerequisites mentioned in [Installation Prerequisites](../../op-manual/installing-k2s.md#prerequisites) must be fulfilled.

* Install [*Go*](https://go.dev/dl/){target="_blank"} for *Windows*.

## Build *Go* projects
Building *Go* based projects is done through [BuildGoExe.ps1](https://github.com/Siemens-Healthineers/K2s/blob/main/smallsetup/common/BuildGoExe.ps1){target="_blank"}

!!! tip
    `bgo.cmd` is a shortcut command to invoke the script `BuildGoExe.ps1`.<br/>
    If you have not installed *K2s* yet, then your `PATH` is not updated with the required locations. In this case, look for bgo.cmd and invoke the build command.

In the below example, `c:\k` is the root of the *Git* repo:
```console
where bgo
C:\k\bin\bgo.cmd
```

Building `httpproxy` *Go* project:
```console
C:\k\bin\bgo -ProjectDir "C:\k\k2s\cmd\httpproxy\" -ExeOutDir "c:\k\bin"
```

!!! info
    The `k2s` CLI can be built without any parameters:
```console
C:\k\bin\bgo
```

To build all *Go* executables:
```console
C:\k\bin\bgo -BuildAll 1
```

If *K2s* is installed then just simply execute the command without the full path:
```console
bgo -ProjectDir "C:\k\k2s\cmd\httpproxy\" -ExeOutDir "c:\k\bin"
bgo -BuildAll 1
```