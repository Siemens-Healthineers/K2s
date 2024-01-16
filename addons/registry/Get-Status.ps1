# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1

kubectl wait --timeout=5s --for=condition=ready -n registry pod/k2s-registry-pod 2>&1 | Out-Null

$isRegistryPodRunningProp = @{Name = 'isRegistryPodRunningProp'; Value = $?; Okay = $? }
if ($isRegistryPodRunningProp.Value -eq $true) {
    $isRegistryPodRunningProp.Message = 'The registry pod is working'
}
else {
    $isRegistryPodRunningProp.Message = "The registry pod is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable registry' and 'k2s addons enable registry'"
} 

$parsedSetupJson = Get-Content -Raw $global:SetupJsonFile | ConvertFrom-Json
$registryMemberExists = Get-Member -InputObject $parsedSetupJson -Name "Registries" -MemberType Properties

$success = $false
if ($registryMemberExists) {
    $registry = $parsedSetupJson.Registries | Where-Object { $_.Contains("k2s-registry.local")}

    $statusCode = curl "http://$registry" | Select-Object -Expand StatusCode
    $success = ($statusCode -eq 200)
}
$isRegistryReachableProp = @{Name = 'isRegistryReachableProp'; Value = $success; Okay = $success }
if ($isRegistryReachableProp.Value -eq $true) {
    $isRegistryReachableProp.Message = "The registry '$registry' is reachable"
}
else {
    $isRegistryReachableProp.Message = "The registry is not reachable. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable registry' and 'k2s addons enable registry'"
} 

return $isRegistryPodRunningProp, $isRegistryReachableProp