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
Gets the location of manifests for the default pv.
#>
function Get-PVConfigDefault {
    return "$PSScriptRoot\manifests\pv-default"
}


<#
.DESCRIPTION
Gets the location of manifests for the pv for the storage addon.
#>
function Get-PVConfigStorage {
    return "$PSScriptRoot\manifests\pv-storage"
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
 The orthanc dicom web ui will be accessible on the following URL: http://k2s.cluster.local/dicom/ui/app/
 Please use https://k2s.cluster.local/dicom/ui/app/ if you have enabled the traefik ingress.
                                        
 Option 2: Port-forwading
 Use port-forwarding to the orthanc dicom web ui using the command below:
 kubectl -n dicom port-forward svc/dicom 8042:8042
 In this case, the orthanc dicom web will be accessible on the following URL: http://localhost:8042/ui/app/
                                        
 DICOM Web APIs are avalaible on the following URL: http(s)://k2s.cluster.local/dicom/dicom-web/
 Example: curl -sS --insecure http://k2s.cluster.local/dicom/dicomweb/studies will return alls studies in the dicom server.
                                        
 By activating this dicom addon you have downloaded at runtime some Orthanc components. 
 Even it is open source, please consider the following license terms for Orthanc components: https://orthanc.uclouvain.be/book/faq/licensing.html 
                                        
'@ -split "`n" | ForEach-Object { Write-Log $_ -Console }
}

<#
.DESCRIPTION
Waits for the dicom pods to be available.
#>
function Wait-ForDicomAvailable {
    return (Wait-ForPodCondition -Condition Ready -Label 'app=dicom' -Namespace 'dicom' -TimeoutSeconds 120)
}