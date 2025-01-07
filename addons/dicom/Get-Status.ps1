# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Import-Module "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k8s-api/k8s-api.module.psm1"

$success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'dicom', 'deployment/dicom').Success

$isOrthancRunningProp = @{Name = 'dicom'; Value = $success; Okay = $success }
if ($isOrthancRunningProp.Value -eq $true) {
    $isOrthancRunningProp.Message = "The dicom Deployment is working"
}
else {
    $isOrthancRunningProp.Message = "The dicom Deployment is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable dicom' and 'k2s addons enable dicom'"
} 

$success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'dicom', 'deployment/mysql').Success

$isMySQlRunningProp = @{Name = 'mysql'; Value = $success; Okay = $success }
if ($isMySQlRunningProp.Value -eq $true) {
    $isMySQlRunningProp.Message = "The mysql Deployment is working"
}
else {
    $isMySQlRunningProp.Message = "The mysql Deployment is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable dicom' and 'k2s addons enable dicom'"
} 

return $isOrthancRunningProp, $isMySQlRunningProp