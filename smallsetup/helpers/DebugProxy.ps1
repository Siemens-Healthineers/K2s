# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1

$env:NODE_NAME = ($(hostname)).ToLower()
$env:KUBE_NETWORK = 'cbr0'

&"$global:KubernetesPath\bin\exe\kube-proxy.exe" --v=6 --proxy-mode=kernelspace --hostname-override=$(hostname) --kubeconfig=`"$global:KubernetesPath\config`" --enable-dsr=false --log-dir=`"$($global:SystemDriveLetter):\var\log\kubeproxy`" --logtostderr=true

