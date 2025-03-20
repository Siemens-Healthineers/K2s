<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

### build the cloudinitisobuilder
### Check latest common parts from: https://github.com/kdomanski/iso9660

#### build executable for windows 
### copy it to bin [Hardcoded c:\ws\k2s as an example]
bgo.cmd -ProjectDir "C:\ws\k2s\k2s\cmd\cloudinitisobuilder" -ExeOutDir "c:\ws\k2s\bin"

