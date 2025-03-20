<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

### build the bridge
### Check latest common parts from: https://github.com/microsoft/windows-container-networking

#### build executable for windows 
### copy it to bin [Hardcoded c:\ws\k2s as an example]
bgo.cmd -ProjectDir "c:\ws\k2s\k2s\cmd\bridge" -ExeOutDir "c:\ws\k2s\bin\cni"

