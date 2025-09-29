<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

### Build the cphook.dll with mingw
## choco install -y mingw (install if not available)
g++ -shared -o ..\..\..\bin\cni\cphook.dll .\cphook\cphook.c -liphlpapi -Wl,--out-implib,libcphook.a

## build compartment launcher
c:\ws\k2s\bin\bgo.cmd -ProjectDir "c:\ws\k2s\k2s\cmd\cplauncher" -ExeOutDir "c:\ws\k2s\bin\cni"
# or for testing
go build -o cplauncher.exe .



