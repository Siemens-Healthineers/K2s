# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$configModule = "$PSScriptRoot\..\..\..\..\..\k2s.infra.module\config\config.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\..\..\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\..\..\k2s.infra.module\log\log.module.psm1"
$systemModule = "$PSScriptRoot\..\..\..\system\system.module.psm1"
Import-Module $logModule, $configModule, $pathModule, $systemModule

$kubePath = Get-KubePath
$kubeBinPath = Get-KubeBinPath


# kubetools
$windowsNode_KubetoolsDirectory = 'kubetools'
$windowsNode_KubeletExe = 'kubelet.exe'
$windowsNode_KubeadmExe = 'kubeadm.exe'
$windowsNode_KubeproxyExe = 'kube-proxy.exe'
$windowsNode_KubectlExe = 'kubectl.exe'

$kubeletConfigDir = (Get-SystemDriveLetter) + ':\var\lib\kubelet'

function Get-KubeletConfigDir {
    return $kubeletConfigDir
}

function Invoke-DownloadKubetoolsArtifacts($downloadsBaseDirectory, $KubernetesVersion, $Proxy) {
    $kubetoolsDownloadsDirectory = "$downloadsBaseDirectory\$windowsNode_KubetoolsDirectory"

    Write-Log "Create folder '$kubetoolsDownloadsDirectory'"
    mkdir $kubetoolsDownloadsDirectory | Out-Null

    if (!$KubernetesVersion.StartsWith('v')) {
        $KubernetesVersion = 'v' + $KubernetesVersion
    }

    Write-Log 'Download kubelet'
    Invoke-DownloadFile "$kubetoolsDownloadsDirectory\$windowsNode_KubeletExe" https://dl.k8s.io/$KubernetesVersion/bin/windows/amd64/$windowsNode_KubeletExe $true $Proxy
    Write-Log 'Download kubeadm'
    Invoke-DownloadFile "$kubetoolsDownloadsDirectory\$windowsNode_KubeadmExe" https://dl.k8s.io/$KubernetesVersion/bin/windows/amd64/$windowsNode_KubeadmExe $true $Proxy
    Write-Log 'Download kubeproxy'
    Invoke-DownloadFile "$kubetoolsDownloadsDirectory\$windowsNode_KubeproxyExe" https://dl.k8s.io/$KubernetesVersion/bin/windows/amd64/$windowsNode_KubeproxyExe $true $Proxy
    Write-Log 'Download kubectl'
    Invoke-DownloadFile "$kubetoolsDownloadsDirectory\$windowsNode_KubectlExe" https://dl.k8s.io/release/$KubernetesVersion/bin/windows/amd64/$windowsNode_KubectlExe $true $Proxy
}

function Invoke-DeployKubetoolsArtifacts($windowsNodeArtifactsDirectory) {
    $kubetoolsArtifactsDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_KubetoolsDirectory"
    if (!(Test-Path "$kubetoolsArtifactsDirectory")) {
        throw "Directory '$kubetoolsArtifactsDirectory' does not exist"
    }
    Write-Log 'Publish kubelet'
    Copy-Item -Path "$kubetoolsArtifactsDirectory\$windowsNode_KubeletExe" -Destination "$kubeBinPath\exe" -Force
    Write-Log 'Publish kubeadm'
    Copy-Item -Path "$kubetoolsArtifactsDirectory\$windowsNode_KubeadmExe" -Destination "$kubeBinPath\exe" -Force
    Write-Log 'Publish kubeproxy'
    Copy-Item -Path "$kubetoolsArtifactsDirectory\$windowsNode_KubeproxyExe" -Destination "$kubeBinPath\exe" -Force
    Write-Log 'Publish kubectl'
    Copy-Item -Path "$kubetoolsArtifactsDirectory\$windowsNode_KubectlExe" -Destination "$kubeBinPath\exe" -Force
    # put a second copy in the bin folder, which is in the PATH
    Copy-Item -Path "$kubetoolsArtifactsDirectory\$windowsNode_KubectlExe" -Destination "$kubeBinPath" -Force
}

function Install-WinKubelet {
    Write-Log 'Registering kubelet service'
    mkdir -force "$(Get-SystemDriveLetter):\var\log\kubelet" | Out-Null

    mkdir -force "$kubeletConfigDir\etc" | Out-Null
    mkdir -force "$kubeletConfigDir\etc\kubernetes" | Out-Null
    mkdir -force "$kubeletConfigDir\etc\kubernetes\manifests" | Out-Null
    mkdir -force "$(Get-SystemDriveLetter):\etc\kubernetes\pki" | Out-Null
    Copy-Item -force "$kubePath\smallsetup\kubeadm-flags.env" $kubeletConfigDir

    if (!(Test-Path "$kubeletConfigDir\etc\kubernetes\pki")) {
        New-Item -path "$kubeletConfigDir\etc\kubernetes\pki" -type SymbolicLink -value "$(Get-SystemDriveLetter):\etc\kubernetes\pki\" | Out-Null
    }

    $global:Powershell = (Get-Command powershell).Source
    $global:PowershellArgs = '-ExecutionPolicy Bypass -NoProfile'
    $global:StartKubeletScript = 'StartKubelet.ps1'
    $global:StartKubeletScriptPath = "$kubePath\smallsetup\common\$global:StartKubeletScript"

    $StartKubeletFileContent = 'Set-Location $PSScriptRoot
    $FileContent = Get-Content -Path "' + (Get-SystemDriveLetter) + ':\var\lib\kubelet\kubeadm-flags.env"
    $global:KubeletArgs = $FileContent.Trim("KUBELET_KUBEADM_ARGS=`"")
    $hn = ($(hostname)).ToLower()
    $cmd = "' + "&'$kubePath\bin\exe\kubelet.exe'" + ' $global:KubeletArgs --root-dir=' + (Get-SystemDriveLetter) + ':\var\lib\kubelet --cert-dir=' + (Get-SystemDriveLetter) + ':\var\lib\kubelet\pki --config=' + (Get-SystemDriveLetter) + ':\var\lib\kubelet\config.yaml --bootstrap-kubeconfig=' + (Get-SystemDriveLetter) + ':\etc\kubernetes\bootstrap-kubelet.conf --kubeconfig=' + "'$kubePath\config'" + ' --hostname-override=$hn --pod-infra-container-image=`"shsk2s.azurecr.io/pause-win:v1.0.0`" --enable-debugging-handlers --cgroups-per-qos=false --enforce-node-allocatable=`"`" --resolv-conf=`"`" --log-dir=' + (Get-SystemDriveLetter) + ':\var\log\kubelet --logtostderr=false --container-runtime=`"remote`" --container-runtime-endpoint=`"npipe:////./pipe/containerd-containerd`""

    Invoke-Expression $cmd'

    Set-Content -Path $global:StartKubeletScriptPath -Value $StartKubeletFileContent

    &$kubeBinPath\nssm install kubelet $global:Powershell
    &$kubeBinPath\nssm set kubelet AppParameters "$global:PowershellArgs \`"Invoke-Command {&'$global:StartKubeletScriptPath'}\`"" | Out-Null
    &$kubeBinPath\nssm set kubelet DependOnService containerd | Out-Null

    &$kubeBinPath\nssm set kubelet AppStdout "$(Get-SystemDriveLetter):\var\log\kubelet\kubelet_stdout.log" | Out-Null
    &$kubeBinPath\nssm set kubelet AppStderr "$(Get-SystemDriveLetter):\var\log\kubelet\kubelet_stderr.log" | Out-Null
    &$kubeBinPath\nssm set kubelet AppStdoutCreationDisposition 4 | Out-Null
    &$kubeBinPath\nssm set kubelet AppStderrCreationDisposition 4 | Out-Null
    &$kubeBinPath\nssm set kubelet AppRotateFiles 1 | Out-Null
    &$kubeBinPath\nssm set kubelet AppRotateOnline 1 | Out-Null
    &$kubeBinPath\nssm set kubelet AppRotateSeconds 0 | Out-Null
    &$kubeBinPath\nssm set kubelet AppRotateBytes 500000 | Out-Null
    &$kubeBinPath\nssm set kubelet Start SERVICE_AUTO_START | Out-Null
}

function Install-WinKubeProxy {
    Write-Log 'Registering kubeproxy service'
    mkdir -force "$(Get-SystemDriveLetter):\var\log\kubeproxy" | Out-Null

    &$kubeBinPath\nssm install kubeproxy "$kubeBinPath\exe\kube-proxy.exe"
    &$kubeBinPath\nssm set kubeproxy AppDirectory "$kubeBinPath\exe" | Out-Null
    $hn = ($(hostname)).ToLower()
    &$kubeBinPath\nssm set kubeproxy AppParameters "--proxy-mode=kernelspace --hostname-override=$hn --kubeconfig=\`"$kubePath\config\`" --enable-dsr=false --log-dir=\`"$(Get-SystemDriveLetter):\var\log\kubeproxy\`" --logtostderr=false" | Out-Null
    &$kubeBinPath\nssm set kubeproxy AppEnvironmentExtra KUBE_NETWORK=cbr0 | Out-Null
    &$kubeBinPath\nssm set kubeproxy DependOnService kubelet | Out-Null
    &$kubeBinPath\nssm set kubeproxy AppStdout "$(Get-SystemDriveLetter):\var\log\kubeproxy\kubeproxy_stdout.log" | Out-Null
    &$kubeBinPath\nssm set kubeproxy AppStderr "$(Get-SystemDriveLetter):\var\log\kubeproxy\kubeproxy_stderr.log" | Out-Null
    &$kubeBinPath\nssm set kubeproxy AppStdoutCreationDisposition 4 | Out-Null
    &$kubeBinPath\nssm set kubeproxy AppStderrCreationDisposition 4 | Out-Null
    &$kubeBinPath\nssm set kubeproxy AppRotateFiles 1 | Out-Null
    &$kubeBinPath\nssm set kubeproxy AppRotateOnline 1 | Out-Null
    &$kubeBinPath\nssm set kubeproxy AppRotateSeconds 0 | Out-Null
    &$kubeBinPath\nssm set kubeproxy AppRotateBytes 500000 | Out-Null
    &$kubeBinPath\nssm set kubeproxy Start SERVICE_AUTO_START | Out-Null
}

Export-ModuleMember -Function *

