# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

# load global settings
&$PSScriptRoot\GlobalVariables.ps1

# set context on windows host (add to existing contexts)
Write-Log 'Reset kubectl config'
$env:KUBECONFIG = $global:KubeConfigDir + '\config'
if (!(Test-Path $global:KubeConfigDir)) {
    mkdir $global:KubeConfigDir -Force | Out-Null
}
if (!(Test-Path $env:KUBECONFIG)) {
    $source = "$global:KubernetesPath\config"
    $target = $global:KubeConfigDir + '\config'
    Copy-Item $source -Destination $target -Force | Out-Null
}
else {
    #kubectl config view
    &$global:KubectlExe config unset contexts.kubernetes-admin@kubernetes
    &$global:KubectlExe config unset clusters.kubernetes
    &$global:KubectlExe config unset users.kubernetes-admin
    Write-Log 'Adding new context and new cluster to Kubernetes config...'
    $source = $global:KubeConfigDir + '\config'
    $target = $global:KubeConfigDir + '\config_backup'
    Copy-Item $source -Destination $target -Force | Out-Null
    $env:KUBECONFIG = "$global:KubeConfigDir\config;$global:KubernetesPath\config"
    #kubectl config view
    $target1 = $global:KubeConfigDir + '\config_new'
    Remove-Item -Path $target1 -Force -ErrorAction SilentlyContinue
    &$global:KubectlExe config view --raw > $target1
    $target2 = $global:KubeConfigDir + '\config'
    Remove-Item -Path $target2 -Force -ErrorAction SilentlyContinue
    Move-Item -Path $target1 -Destination $target2 -Force
}
&$global:KubectlExe config use-context kubernetes-admin@kubernetes
Write-Log "Config from user directory:"
$env:KUBECONFIG = ''
&$global:KubectlExe config view