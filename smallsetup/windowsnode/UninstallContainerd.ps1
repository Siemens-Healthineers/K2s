# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1
$ErrorActionPreference = 'Continue'
if ($Trace) {
    Set-PSDebug -Trace 1
}

Write-Log 'Stop service containerd'
Stop-Service containerd -ErrorAction SilentlyContinue
Write-Log 'Unregister service'
# &$global:KubernetesPath\containerd\containerd.exe --unregister-service
Remove-ServiceIfExists 'containerd'

Remove-Item -Path "$global:KubernetesPath\containerd\config.toml" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$global:KubernetesPath\containerd\flannel-l2bridge.conf" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$global:KubernetesPath\containerd\cni" -Recurse -Force -ErrorAction SilentlyContinue

Remove-Item -Path "$global:KubernetesPath\cfg\containerd\config.toml" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$global:KubernetesPath\cfg\containerd\flannel-l2bridge.conf" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$global:KubernetesPath\cfg\containerd\cni" -Recurse -Force -ErrorAction SilentlyContinue


if ($global:PurgeOnUninstall) {
    Remove-Item -Path "$global:KubernetesPath\containerd\*.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:KubernetesPath\containerd\*.zip" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:KubernetesPath\containerd\*.tar.gz" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:KubernetesPath\containerd\root" -Force -Recurse -ErrorAction SilentlyContinue

    Remove-Item -Path "$global:KubernetesPath\bin\containerd\*.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:KubernetesPath\bin\containerd\*.zip" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:KubernetesPath\bin\containerd\*.tar.gz" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:KubernetesPath\cfg\containerd\root" -Force -Recurse -ErrorAction SilentlyContinue
}

# system prune
# crictl rmi --prune
