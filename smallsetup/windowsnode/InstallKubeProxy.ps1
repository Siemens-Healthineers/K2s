# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1

Write-Log 'Registering kubeproxy service'
&$global:NssmInstallDirectory\nssm install kubeproxy $global:ExecutableFolderPath\kube-proxy.exe
&$global:NssmInstallDirectory\nssm set kubeproxy AppDirectory $global:ExecutableFolderPath | Out-Null
$hn = ($(hostname)).ToLower()
&$global:NssmInstallDirectory\nssm set kubeproxy AppParameters "--proxy-mode=kernelspace --hostname-override=$hn --kubeconfig=\`"$global:KubernetesPath\config\`" --enable-dsr=false " | Out-Null
&$global:NssmInstallDirectory\nssm set kubeproxy AppEnvironmentExtra KUBE_NETWORK=cbr0 | Out-Null
&$global:NssmInstallDirectory\nssm set kubeproxy DependOnService kubelet | Out-Null
&$global:NssmInstallDirectory\nssm set kubeproxy AppStdout "$($global:SystemDriveLetter):\var\log\kubeproxy\kubeproxy_stdout.log" | Out-Null
&$global:NssmInstallDirectory\nssm set kubeproxy AppStderr "$($global:SystemDriveLetter):\var\log\kubeproxy\kubeproxy_stderr.log" | Out-Null
&$global:NssmInstallDirectory\nssm set kubeproxy AppStdoutCreationDisposition 4 | Out-Null
&$global:NssmInstallDirectory\nssm set kubeproxy AppStderrCreationDisposition 4 | Out-Null
&$global:NssmInstallDirectory\nssm set kubeproxy AppRotateFiles 1 | Out-Null
&$global:NssmInstallDirectory\nssm set kubeproxy AppRotateOnline 1 | Out-Null
&$global:NssmInstallDirectory\nssm set kubeproxy AppRotateSeconds 0 | Out-Null
&$global:NssmInstallDirectory\nssm set kubeproxy AppRotateBytes 500000 | Out-Null
&$global:NssmInstallDirectory\nssm set kubeproxy Start SERVICE_AUTO_START | Out-Null