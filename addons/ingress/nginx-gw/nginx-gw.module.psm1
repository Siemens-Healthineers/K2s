# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Contains common methods for installing and uninstalling nginx-gw
#>
function Get-ExternalDnsConfigDir {
    return "$PSScriptRoot\..\..\common\manifests\external-dns"
}

function Get-NginxGatewayYamlDir {
    return "$PSScriptRoot\manifests"
}

function Get-NginxGatewayCrdsDir {
    return "$PSScriptRoot\manifests\crds"
}

<#
.DESCRIPTION
Determines if the security service is deployed in the cluster
#>
function Test-SecurityAddonAvailability {
    $existingServices = (Invoke-Kubectl -Params 'get', 'service', '-n', 'security', '-o', 'yaml').Output
    if ("$existingServices" -match '.* keycloak .*') {
        return $true
    }
    return $false
}

<#
.SYNOPSIS
Creates TLS certificate for nginx-gw using cert-manager

.DESCRIPTION
Installs temporary cert-manager instance to create self-signed TLS certificate,
then removes cert-manager to avoid conflicts with security addon.
Only runs when security addon is NOT enabled.

.PARAMETER Namespace
The namespace where the TLS secret should be created

.PARAMETER SecretName
The name of the TLS secret to create

.PARAMETER DnsName
The DNS name for the certificate (default: k2s.cluster.local)
#>
function New-TlsCertificateWithCertManager {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Namespace,
        
        [Parameter(Mandatory = $false)]
        [string]$SecretName = 'k2s-cluster-local-tls',
        
        [Parameter(Mandatory = $false)]
        [string]$DnsName = 'k2s.cluster.local'
    )
    
    Write-Log "Creating TLS certificate '$SecretName' in namespace '$Namespace'" -Console
    
    try {
        # Apply Certificate resource
        Write-Log 'Creating Certificate resource for self-signed certificate' -Console
        $certificateYaml = "$PSScriptRoot\manifests\k2s-cluster-local-tls-certificate.yaml"
        
        if (-not (Test-Path $certificateYaml)) {
            Write-Log "Error: Certificate manifest not found at $certificateYaml" -Error
            return $false
        }
        
        (Invoke-Kubectl -Params 'apply', '-f', $certificateYaml).Output | Write-Log
        
        # Wait for certificate to be issued and secret to be created
        Write-Log 'Waiting for cert-manager to issue certificate and create secret...' -Console
        $maxRetries = 30
        $retryCount = 0
        $certificateIssued = $false
        
        while ($retryCount -lt $maxRetries) {
            $secretCheck = (Invoke-Kubectl -Params 'get', 'secret', $SecretName, '-n', $Namespace, '--ignore-not-found').Output
            if (-not [string]::IsNullOrWhiteSpace($secretCheck)) {
                $certificateIssued = $true
                Write-Log "Certificate issued successfully - Secret '$SecretName' created" -Console
                break
            }
            
            Start-Sleep -Seconds 2
            $retryCount++
        }
        
        if (-not $certificateIssued) {
            Write-Log "Warning: Timeout waiting for certificate issuance after $($maxRetries * 2) seconds" -Console
            Write-Log "Check status with: kubectl describe certificate $SecretName -n $Namespace" -Console
            return $false
        }
        return $true
    }
    catch {
        Write-Log "Error creating TLS certificate: $_" -Error
        return $false
    }
}

Export-ModuleMember -Function Get-ExternalDnsConfigDir, Get-NginxGatewayYamlDir, Get-NginxGatewayCrdsDir, Test-SecurityAddonAvailability, New-TlsCertificateWithCertManager