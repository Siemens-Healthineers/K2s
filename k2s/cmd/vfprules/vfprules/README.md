<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

## 1. Build the OS specfic images

### Setup build environment
### -> open x64 studio command window

### Build the dll with the cl compiler from Micorosft
cl /LD vfprules.c /Fe:vfprules.dll /link /subsystem:console

cl /D_USRDLL /D_WINDLL vfprules.c /MT /link /DLL /subsystem:console /OUT:vfprules.dll
### or with gcc
gcc -shared -o vfprules.dll vfprules.c

### Cleanup
del /s *.dll
del /s *.obj



