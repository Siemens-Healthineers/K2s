# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
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
    kubectl config unset contexts.kubernetes-admin@kubernetes
    kubectl config unset clusters.kubernetes
    kubectl config unset users.kubernetes-admin
    Write-Log 'Adding new context and new cluster to Kubernetes config...'
    $source = $global:KubeConfigDir + '\config'
    $target = $global:KubeConfigDir + '\config_backup'
    Copy-Item $source -Destination $target -Force | Out-Null
    $env:KUBECONFIG = "$global:KubeConfigDir\config;$global:KubernetesPath\config"
    #kubectl config view
    $target1 = $global:KubeConfigDir + '\config_new'
    Remove-Item -Path $target1 -Force -ErrorAction SilentlyContinue
    kubectl config view --raw > $target1
    $target2 = $global:KubeConfigDir + '\config'
    Remove-Item -Path $target2 -Force -ErrorAction SilentlyContinue
    Move-Item -Path $target1 -Destination $target2 -Force
}
kubectl config use-context kubernetes-admin@kubernetes
Write-Log "Config from user directory:"
$env:KUBECONFIG = ''
kubectl config view