# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$infraModule = "$PSScriptRoot/../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"

Import-Module $infraModule

$binPath = Get-KubeBinPath
$nerdctlExe = "$binPath\nerdctl.exe"
$crictlExe = "$binPath\crictl.exe"

function Get-NerdctlExe {
    return $nerdctlExe    
}

function Get-CrictlExe {
    return $crictlExe    
}
