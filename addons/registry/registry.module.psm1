# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$k8sApiModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k8s-api/k8s-api.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.node.module\k2s.node.module.psm1"

Import-Module $infraModule, $k8sApiModule, $nodeModule

function Set-ContainerdConfig() {
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


<#
.DESCRIPTION
Writes the usage notes for dashboard for the user.
#>
function Write-RegistryUsageForUser {
    param(
        [Parameter()]
        [String]
        $Name
    )
    @"
                                        USAGE NOTES
 Registry is available via '$Name'
 
 In order to push your images to the private registry you have to tag your images as in the following example:
 $Name/<yourImageName>:<yourImageTag>
"@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
}

function Set-InsecureRegistry {
    param(
        [Parameter()]
        [String]
        $Name
    )

    # Linux (cri-o)
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "grep location=\\\""k2s.*\\\"" /etc/containers/registries.conf | sudo sed -i -z 's/\[\[registry]]\nlocation=\\\""k2s.*\\\""\ninsecure=true/[[registry]]\nlocation=\\\""$Name\\\""\ninsecure=true/g' /etc/containers/registries.conf").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "grep location=\\\""k2s.*\\\"" /etc/containers/registries.conf || echo -e `'\n[[registry]]\nlocation=\""$Name\""\ninsecure=true`' | sudo tee -a /etc/containers/registries.conf").Output | Write-Log

    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo systemctl daemon-reload').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo systemctl restart crio').Output | Write-Log

    # Windows (containerd)
    Remove-Item -Force "$(Get-SystemDriveLetter)\etc\containerd\k2s.registry.local*" -Recurse -Confirm:$False -ErrorAction SilentlyContinue

    $Name = $Name -replace ':',''

@"
server = "http://k2s.registry.local:30500"

[host."http://k2s.registry.local:30500"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
  plain_http = true
"@ | Set-Content -Path "$(Get-SystemDriveLetter)\etc\containerd\$Name\hosts.toml"
}

function Remove-InsecureRegistry {
    # Linux (cri-o)
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "grep location=\\\""k2s.*\\\"" /etc/containers/registries.conf | sudo sed -i -z 's/\[\[registry]]\nlocation=\\\""k2s.*\\\""\ninsecure=true//g' /etc/containers/registries.conf").Output | Write-Log

    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo systemctl daemon-reload').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo systemctl restart crio').Output | Write-Log

    # Windows (containerd)
    Remove-Item -Force "$(Get-SystemDriveLetter)\etc\containerd\k2s.registry.local*" -Recurse -Confirm:$False -ErrorAction SilentlyContinue
}

function Update-NodePort {
    Write-Log "  Applying nodeport service manifest for registry..." -Console
    (Invoke-Kubectl -Params 'apply', '-f', "$PSScriptRoot\manifests\registry\service-nodeport.yaml").Output | Write-Log
}

function Remove-NodePort {
    Write-Log "  Removing nodeport service manifest for registry..." -Console
    (Invoke-Kubectl -Params 'delete', '-f', "$PSScriptRoot\manifests\registry\service-nodeport.yaml --ignore-not-found").Output | Write-Log
}