# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Import-Module "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"

Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=ready', '-n', 'registry', 'pod/k2s-registry-pod' | Out-Null

$isRegistryPodRunningProp = @{Name = 'IsRegistryPodRunning'; Value = $?; Okay = $? }
if ($isRegistryPodRunningProp.Value -eq $true) {
    $isRegistryPodRunningProp.Message = 'The registry pod is working'
}
else {
    $isRegistryPodRunningProp.Message = "The registry pod is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable registry' and 'k2s addons enable registry'"
} 

$registries = Get-RegistriesFromSetupJson

$success = $false
if ($registries) {
    $registry = $registries | Where-Object { $_.Contains('k2s-registry.local') }

    $statusCode = curl "http://$registry" | Select-Object -Expand StatusCode
    $success = ($statusCode -eq 200)
}

$isRegistryReachableProp = @{Name = 'IsRegistryReachable'; Value = $success; Okay = $success }
if ($isRegistryReachableProp.Value -eq $true) {
    $isRegistryReachableProp.Message = "The registry '$registry' is reachable"
}
else {
    $isRegistryReachableProp.Message = "The registry is not reachable. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable registry' and 'k2s addons enable registry'"
} 

return $isRegistryPodRunningProp, $isRegistryReachableProp