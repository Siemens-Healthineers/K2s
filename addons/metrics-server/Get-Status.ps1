# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

&$global:KubectlExe wait --timeout=5s --for=condition=Available -n kube-system deployment/metrics-server 2>&1 | Out-Null

$isMetricsServerRunningProp = @{Name = 'isMetricsServerRunningProp'; Value = $?; Okay = $? }
if ($isMetricsServerRunningProp.Value -eq $true) {
    $isMetricsServerRunningProp.Message = 'The metrics server is working'
}
else {
    $isMetricsServerRunningProp.Message = "The metrics server is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable metrics-server' and 'k2s addons enable metrics-server'"
} 

return ,@($isMetricsServerRunningProp)