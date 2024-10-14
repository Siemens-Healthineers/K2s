<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

### build the bridge
### Check latest common parts from: https://github.com/microsoft/windows-container-networking

#### build executable for windows 
### copy it to bin [Hardcoded c:\k as an example]
bgo.cmd -ProjectDir "c:\k\k2s\cmd\bridge" -ExeOutDir "c:\k\bin\cni"

