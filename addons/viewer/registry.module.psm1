# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$k8sApiModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k8s-api/k8s-api.module.psm1"
$serviceModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.node.module\windowsnode\services\services.module.psm1"

Import-Module $infraModule, $k8sApiModule, $serviceModule

function Deploy-IngressForRegistry([string]$Ingress) {
    switch ($Ingress) {
        'nginx' {
            (Invoke-Kubectl -Params 'apply', '-f', "$PSScriptRoot\manifests\k2s-registry-nginx-ingress.yaml").Output | Write-Log
            break
        }
        'traefik' {
            (Invoke-Kubectl -Params 'apply', '-f', "$PSScriptRoot\manifests\k2s-registry-traefik-ingress.yaml").Output | Write-Log
            break
        }
    }
}

function Set-Containerd-Config() {
    param(
        [Parameter()]
        [String]
        $registryName,
        [Parameter()]
        [String]
        $authJson
    )
    $containerdConfig = "$(Get-KubePath)\cfg\containerd\config.toml"
    Write-Log "Changing $containerdConfig"

    $dockerConfig = $authJson | ConvertFrom-Json
    $dockerAuth = $dockerConfig.psobject.properties['auths'].value
    $authk2s = $dockerAuth.psobject.properties["$registryName"].value
    $auth = $authk2s.psobject.properties['auth'].value

    $authPlaceHolder = Get-Content $containerdConfig | Select-String '#auth_k2s_registry' | Select-Object -ExpandProperty Line
    if ( $authPlaceHolder ) {
        $content = Get-Content $containerdConfig
        $content | ForEach-Object { $_.replace($authPlaceHolder, "        [plugins.""io.containerd.grpc.v1.cri"".registry.configs.""$registryName"".auth] #auth_k2s_registry") } | Set-Content $containerdConfig
    }

    $authValuePlaceHolder = Get-Content $containerdConfig | Select-String '#auth_value_k2s_registry' | Select-Object -ExpandProperty Line
    if ( $authValuePlaceHolder ) {
        $content = Get-Content $containerdConfig
        $content | ForEach-Object { $_ -replace $authValuePlaceHolder, "          auth = ""$auth"" #auth_value_k2s_registry" } | Set-Content $containerdConfig
    }

    $tlsPlaceHolder = Get-Content $containerdConfig | Select-String '#tls_k2s_registry' | Select-Object -ExpandProperty Line
    if ( $tlsPlaceHolder ) {
        $content = Get-Content $containerdConfig
        $content | ForEach-Object { $_.replace($tlsPlaceHolder, "        [plugins.""io.containerd.grpc.v1.cri"".registry.configs.""$registryName"".tls] #tls_k2s_registry") } | Set-Content $containerdConfig
    }

    $mirrorPlaceHolder = Get-Content $containerdConfig | Select-String '#mirror_k2s_registry' | Select-Object -ExpandProperty Line
    if ( $mirrorPlaceHolder ) {
        $content = Get-Content $containerdConfig
        $content | ForEach-Object { $_.replace($mirrorPlaceHolder, "        [plugins.""io.containerd.grpc.v1.cri"".registry.mirrors.""$registryName""] #mirror_k2s_registry") } | Set-Content $containerdConfig
    }

    $mirrorValuePlaceHolder = Get-Content $containerdConfig | Select-String '#mirror_value_k2s_registry' | Select-Object -ExpandProperty Line
    if ( $mirrorValuePlaceHolder ) {
        $content = Get-Content $containerdConfig
        $content | ForEach-Object { $_.replace($mirrorValuePlaceHolder, "          endpoint = [""http://$registryName""] #mirror_value_k2s_registry") } | Set-Content $containerdConfig
    }
}

function Restart-Services() {
    Write-Log 'Restarting services' -Console
    Stop-NssmService('kubeproxy')
    Stop-NssmService('kubelet')
    Restart-NssmService('containerd')
    Start-NssmService('kubelet')
    Start-NssmService('kubeproxy')
}