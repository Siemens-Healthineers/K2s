# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Import-Module "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k8s-api/k8s-api.module.psm1"

$success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'dicom', 'deployment/orthanc').Success

$isOrthancRunningProp = @{Name = 'orthanc'; Value = $success; Okay = $success }
if ($isOrthancRunningProp.Value -eq $true) {
    $isOrthancRunningProp.Message = 'The orthanc Deployment is working'
}
else {
    $isOrthancRunningProp.Message = "The orthanc Deployment is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable dicom' and 'k2s addons enable dicom'"
} 

return $isOrthancRunningProp