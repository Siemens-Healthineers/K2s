# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$logModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/log/log.module.psm1"
$k8sApiModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k8s-api/k8s-api.module.psm1"

Import-Module $logModule, $k8sApiModule

<#
.DESCRIPTION
Gets the location of manifests to deploy dicom server.
#>
function Get-DicomConfig {
    return "$PSScriptRoot\manifests\dicom"
}

<#
.DESCRIPTION
Writes the usage notes for dicom server user interface for the user.
#>
function Write-UsageForUser {
    @'
                                        USAGE NOTES
 To open dicom server UI, please use one of the options:
 
 Option 1: Access via ingress
 Please install either ingress nginx addon or ingress traefik addon from k2s.
 or you can install them on your own.
 Enable ingress controller via k2s cli
 eg. k2s addons enable ingress nginx
 Once the ingress controller is running in the cluster, run the command to enable dicom
 k2s addons enable dicom
 The orthanc dicom web ui will be accessible on the following URL: https://k2s.cluster.local/dicom/ui/app/

 Option 2: Port-forwading
 Use port-forwarding to the orthanc dicom web ui using the command below:
 kubectl -n dicom port-forward svc/dicom 8042:8042
 In this case, the orthanc dicom web will be accessible on the following URL: http://localhost:8042/ui/app/

 DICOM Web APIs are avalaible on the following URL: https://k2s.cluster.local/dicom/dicom-web/
 Example: curl -sS --insecure https://k2s.cluster.local/dicom/dicomweb/studies will return alls studies in the dicom server.
 
'@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
}

<#
.DESCRIPTION
Waits for the dicom pods to be available.
#>
function Wait-ForDicomAvailable {
    return (Wait-ForPodCondition -Condition Ready -Label 'app=dicom' -Namespace 'dicom' -TimeoutSeconds 120)
}