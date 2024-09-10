<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

## 1. Build the OS specfic images

### Setup build environment
### -> open x64 studio command window

### Build the dll with Visual Studio
### Open vcxproj file with Visual Studio
### or set build env in a shell
"C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\VC\Auxiliary\Build\vcvars64.bat"
### or
"C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\VC\Auxiliary\Build\vcvars64.bat"
### Build the dll with cl
msbuild .\k2s\cmd\vfprules\vfprules\vfprules.vcxproj -t:rebuild -verbosity:diag -property:Configuration=Release /property:Platform=x64

### Cleanup
del /s *.dll
del /s *.obj





