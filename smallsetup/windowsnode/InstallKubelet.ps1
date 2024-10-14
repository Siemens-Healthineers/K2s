# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Use containerd')]
    [switch] $UseContainerd = $false
)

# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1

Write-Log "Registering kubelet service, UseContainerd=$UseContainerd"
$global:Powershell = (Get-Command powershell).Source
$global:PowershellArgs = '-ExecutionPolicy Bypass -NoProfile'
$global:StartKubeletScript = 'StartKubelet.ps1'
$global:StartKubeletScriptPath = "$global:KubernetesPath\smallsetup\common\$global:StartKubeletScript"

if (!$UseContainerd) {
    $StartKubeletFileContent = 'Set-Location $PSScriptRoot
    $FileContent = Get-Content -Path "' + "$global:SystemDriveLetter" + ':\var\lib\kubelet\kubeadm-flags.env"
    $global:KubeletArgs = $FileContent.Trim("KUBELET_KUBEADM_ARGS=`"")
    $hn = ($(hostname)).ToLower()
    $cmd = "' + "&'$global:KubernetesPath\bin\exe\kubelet.exe'" + ' $global:KubeletArgs --root-dir=' + "$global:SystemDriveLetter" + ':\var\lib\kubelet --cert-dir=' + "$global:SystemDriveLetter" + ':\var\lib\kubelet\pki --config=' + "$global:SystemDriveLetter" + ':\var\lib\kubelet\config.yaml --bootstrap-kubeconfig=' + "$global:SystemDriveLetter" + ':\etc\kubernetes\bootstrap-kubelet.conf --kubeconfig=' + "'$global:KubernetesPath\config'" + ' --hostname-override=$hn --cgroups-per-qos=false --enforce-node-allocatable=`"`""

    Invoke-Expression $cmd'
}
else {
    $StartKubeletFileContent = 'Set-Location $PSScriptRoot
    $FileContent = Get-Content -Path "' + "$global:SystemDriveLetter" + ':\var\lib\kubelet\kubeadm-flags.env"
    $global:KubeletArgs = $FileContent.Trim("KUBELET_KUBEADM_ARGS=`"")
    $hn = ($(hostname)).ToLower()
    $cmd = "' + "&'$global:KubernetesPath\bin\exe\kubelet.exe'" + ' $global:KubeletArgs --root-dir=' + "$global:SystemDriveLetter" + ':\var\lib\kubelet --cert-dir=' + "$global:SystemDriveLetter" + ':\var\lib\kubelet\pki --config=' + "$global:SystemDriveLetter" + ':\var\lib\kubelet\config.yaml --bootstrap-kubeconfig=' + "$global:SystemDriveLetter" + ':\etc\kubernetes\bootstrap-kubelet.conf --kubeconfig=' + "'$global:KubernetesPath\config'" + ' --hostname-override=$hn --container-runtime-endpoint=`"npipe:////./pipe/containerd-containerd`" --cgroups-per-qos=false --enforce-node-allocatable=`"`""

    Invoke-Expression $cmd'
}
Set-Content -Path $global:StartKubeletScriptPath -Value $StartKubeletFileContent

&$global:NssmInstallDirectory\nssm install kubelet $global:Powershell
&$global:NssmInstallDirectory\nssm set kubelet AppParameters "$global:PowershellArgs \`"Invoke-Command {&'$global:StartKubeletScriptPath'}\`"" | Out-Null
if (!$UseContainerd) {
    &$global:NssmInstallDirectory\nssm set kubelet DependOnService docker | Out-Null
}
else {
    &$global:NssmInstallDirectory\nssm set kubelet DependOnService containerd | Out-Null
}

&$global:NssmInstallDirectory\nssm set kubelet AppStdout "$($global:SystemDriveLetter):\var\log\kubelet\kubelet_stdout.log" | Out-Null
&$global:NssmInstallDirectory\nssm set kubelet AppStderr "$($global:SystemDriveLetter):\var\log\kubelet\kubelet_stderr.log" | Out-Null
&$global:NssmInstallDirectory\nssm set kubelet AppStdoutCreationDisposition 4 | Out-Null
&$global:NssmInstallDirectory\nssm set kubelet AppStderrCreationDisposition 4 | Out-Null
&$global:NssmInstallDirectory\nssm set kubelet AppRotateFiles 1 | Out-Null
&$global:NssmInstallDirectory\nssm set kubelet AppRotateOnline 1 | Out-Null
&$global:NssmInstallDirectory\nssm set kubelet AppRotateSeconds 0 | Out-Null
&$global:NssmInstallDirectory\nssm set kubelet AppRotateBytes 500000 | Out-Null
&$global:NssmInstallDirectory\nssm set kubelet Start SERVICE_AUTO_START | Out-Null