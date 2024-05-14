# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$nssmModule = "$PSScriptRoot/../../lib\modules\k2s\k2s.node.module\windowsnode\downloader\artifacts\nssm\nssm.module.psm1"
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"

Import-Module $infraModule, $nssmModule

$serviceName = 'nginx-ext'

function Get-ServiceName {
    return $serviceName
}

function Remove-Nginx {
    Remove-ServiceIfExists $serviceName | Write-Log
    Remove-Item -Recurse -Force "$(Get-KubeBinPath)\nginx" | Out-Null    
}

Export-ModuleMember -Function Get-ServiceName, Remove-Nginx