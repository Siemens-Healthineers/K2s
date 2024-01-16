# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

&$PSScriptRoot\..\..\..\smallsetup\common\GlobalVariables.ps1

&$global:KubernetesPath\smallsetup\common\BuildGoExe.ps1 -ProjectDir "$global:KubernetesPath\pkg\util\yaml2json" -ExeOutDir "$global:KubernetesPath\bin"