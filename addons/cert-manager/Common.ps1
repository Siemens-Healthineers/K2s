# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Contains common methods for installing and uninstalling cert-manager
#>

<#
.DESCRIPTION
Gets the location of manifests to deploy cert-manager
#>
function Get-CertManagerConfig {
    return "$PSScriptRoot\manifests\cert-manager.yaml"
}

<#
.DESCRIPTION
Gets the location of nginx ingress yaml for dashboard
#>
function Get-CAIssuerConfig {
    return "$PSScriptRoot\manifests\ca-issuer.yaml"
}

<#
.DESCRIPTION
Writes the usage notes for cert-manager for the user.
#>
function Write-UsageForUser {
    @'
                                        USAGE NOTES

cert-manger is installed and configured to manage certificates for your cluster.
In terms of cert-manager, as described here: https://cert-manager.io/docs/, we configured
a global ClusterIssuer of type CA (Certification Authority) named:

                                        k2s-ca-issuer            

If you have also enabled the ingress-nginx and dashboard addons, you can inspect the
server certificate by visiting the dashboard URL in your browser and clicking on the lock icon:
https://k2s-dashboard.local

You can follow the pattern as described here to secure ingresses exposed by your kubernetes applications:
https://cert-manager.io/docs/usage/ingress/#how-it-works

In the annotation section, you need these lines:

apiVersion: networking.k8s.io/v1
kind: Ingress...
metadata:
  annotations:
    ...
    cert-manager.io/cluster-issuer: k2s-ca-issuer
    cert-manager.io/common-name: your-ingress-host.domain
...
spec:
...
  tls:
  - hosts:
    - your-ingress-host.domain
    secretName: your-secret-name

cert-manager will observe annoations, create a certificate and store it in the secret named 'your-secret-name'

You can also use the command line interface cmctl.exe to interact with cert-manager.
'@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
}

<#
.DESCRIPTION
Waits for the cert-manager pods to be available.
#>
function Wait-ForCertManagerAvailable {
    $out = &$global:BinPath\exe\cmctl.exe check api --wait=2m
    if ($out -match 'The cert-manager API is ready') {
        return $true
    }
    else {
        return $false
    }
}
