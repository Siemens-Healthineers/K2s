<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

## 1. Build the OS specfic images

### Setup build environment
### -> open x64 studio command window

### Build the dll with the cl compiler from Microsoft (start from an x64 dev env)
cl /LD vfprules.c /Fe:..\..\..\..\bin\cni\vfprules.dll /link ntdll.lib /subsystem:console

### or with gcc
gcc -shared -o vfprules.dll vfprules.c

### Cleanup
del /s *.dll
del /s *.obj





