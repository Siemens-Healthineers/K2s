# SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule

<#
.DESCRIPTION
Gets the location of manifests to deploy viewer viewer
#>
function Get-ViewerConfig {
    return "$PSScriptRoot\manifests\viewer"
}

<#
.DESCRIPTION
Writes the usage notes for viewer for the user.
#>
function Write-ViewerUsageForUser {
    @"
                VIEWER ADDON - USAGE NOTES
 To open the viewer, please use one of the options:

 Option 1: Access via ingress
 Please install either ingress nginx or ingress traefik addon from k2s
 or you can install them on your own. 
 Enable ingress controller via k2s cli
 eg. k2s addons enable ingress nginx
 Once the ingress controller is running in the cluster, run the command to enable viewer 
 k2s addons enable viewer
 the viewer will be accessible on the following URL: http://k2s.cluster.local/viewer

 Option 2: Port-forwarding
 Use port-forwarding to the viewer using the command below:
 kubectl -n viewer port-forward svc/viewerwebapp 8443:80

 In this case, the viewer will be accessible on the following URL: http://localhost:8443/viewer/
 It is not necessary to use port 8443. Please feel free to use a port number of your choice.


 On opening the URL in the browser, the login page appears.
 Please select `"Skip`".

 The viewer is opened in the browser.
 
"@ -split "`n" | ForEach-Object { Write-Log $_ -Console }
}

<#
.DESCRIPTION
Waits for the viewer pods to be available.
#>
function Wait-ForViewerAvailable {
    return (Wait-ForPodCondition -Condition Ready -Label 'app=viewerwebapp' -Namespace 'viewer' -TimeoutSeconds 120)
}

<#
.DESCRIPTION
Determines if the dicom addon is deployed in the cluster
#>
function Test-DicomAddonAvailability {
    $existingServices = (Invoke-Kubectl -Params 'get', 'service', '-n', 'dicom', '-o', 'yaml').Output 
    if ("$existingServices" -match '.*dicom.*') {
        return $true
    }
    return $false
}

<#
.DESCRIPTION
Updates the defaultDataSourceName in the viewer configmap.
#>
function Update-ConfigMap {
    param (
        [string]$FilePath,
        [string]$NewDefaultDataSourceName
    )

    # Read the content of the configmap.yaml file
    $configMapContent = Get-Content -Path $FilePath -Raw

    # Replace the defaultDataSourceName value in memory
    # Construct the replacement string
    $replacementString = '"defaultDataSourceName": "' + $NewDefaultDataSourceName + '"'

    # Replace the defaultDataSourceName value in memory
    $updatedConfigMapContent = $configMapContent -replace '"defaultDataSourceName": "dicomweb"', $replacementString
    # Create a temporary file to store the updated content
    $tempFilePath = [System.IO.Path]::GetTempFileName()
    Set-Content -Path $tempFilePath -Value $updatedConfigMapContent

    # Apply the updated configmap to the Kubernetes cluster
    Invoke-Kubectl -Params 'apply', '-f', $tempFilePath, '-n', 'viewer'
    # Restart the viewerwebapp deployment to apply the changes
    Invoke-Kubectl -Params 'rollout', 'restart', 'deployment/viewerwebapp', '-n', 'viewer'

    # Remove the temporary file
    Remove-Item -Path $tempFilePath

    Write-Output "ConfigMap has been updated and reapplied with defaultDataSourceName set to $NewDefaultDataSourceName."
}

<#
.DESCRIPTION
Updates the viewer configmap based on the availability of the DICOM addon.
#>
function Update-ViewerConfigMap {
    # Define the file path
    $filePath = "$PSScriptRoot\manifests\viewer\configmap.yaml"

    # Check the availability of the DICOM addon
    if (Test-DicomAddonAvailability) {
        # Call Update-ConfigMap with defaultDataSourceName set to dicomweb2
        Update-ConfigMap -FilePath $filePath -NewDefaultDataSourceName "dicomweb2"
    } else {
        # Call Update-ConfigMap with defaultDataSourceName set to dicomweb
        Update-ConfigMap -FilePath $filePath -NewDefaultDataSourceName "dicomweb"
    }
}