# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

&$PSScriptRoot\..\..\..\smallsetup\common\GlobalVariables.ps1

&$global:KubernetesPath\smallsetup\common\BuildGoExe.ps1 -ProjectDir "$global:KubernetesPath\cmd\yaml2json" -ExeOutDir "$global:KubernetesPath\bin"
