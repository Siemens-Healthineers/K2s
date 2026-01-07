# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
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
        # Check if secret already exists
        $secretExists = (Invoke-Kubectl -Params 'get', 'secret', $SecretName, '-n', $Namespace, '--ignore-not-found').Output
        if (-not [string]::IsNullOrWhiteSpace($secretExists)) {
            Write-Log "TLS certificate '$SecretName' already exists, skipping creation" -Console
            return $true
        }
        
        # Install cert-manager temporarily in unique namespace to avoid conflicts
        Write-Log 'Installing temporary cert-manager for TLS certificate generation' -Console
        $tempCertManagerNamespace = 'nginx-gw-cert-manager-temp'
        $certManagerYaml = "$PSScriptRoot\manifests\cert-manager.yaml"
        
        if (-not (Test-Path $certManagerYaml)) {
            Write-Log "Error: cert-manager manifest not found at $certManagerYaml" -Error
            return $false
        }
        
        (Invoke-Kubectl -Params 'apply', '-f', $certManagerYaml).Output | Write-Log
        
        # Wait for cert-manager pods to be ready
        Write-Log 'Waiting for cert-manager pods to become ready...' -Console
        $certManagerReady = Wait-ForPodCondition -Condition Ready -Label 'app.kubernetes.io/instance=cert-manager' -Namespace $tempCertManagerNamespace -TimeoutSeconds 120
        
        if (-not $certManagerReady) {
            Write-Log 'Warning: cert-manager pods did not become ready within timeout' -Console
            return $false
        }
        
        Write-Log 'cert-manager pods are ready, waiting for webhook to initialize...' -Console
        
        # Wait for webhook CA secret to exist (indicates webhook is fully ready)
        $maxWebhookRetries = 30
        $webhookRetryCount = 0
        $webhookReady = $false
        
        while ($webhookRetryCount -lt $maxWebhookRetries) {
            $caSecret = (Invoke-Kubectl -Params 'get', 'secret', 'cert-manager-webhook-ca', '-n', $tempCertManagerNamespace, '--ignore-not-found').Output
            if (-not [string]::IsNullOrWhiteSpace($caSecret)) {
                $webhookReady = $true
                Write-Log 'cert-manager webhook is ready' -Console
                break
            }
            
            Start-Sleep -Seconds 2
            $webhookRetryCount++
        }
        
        if (-not $webhookReady) {
            Write-Log 'Warning: cert-manager webhook did not become ready within timeout' -Console
            return $false
        }
        
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
        
        # Clean up cert-manager to avoid conflicts with security addon
        Write-Log 'Cleaning up temporary cert-manager installation...' -Console
        
        # Delete Certificate and Issuer resources first
        (Invoke-Kubectl -Params 'delete', '-f', $certificateYaml, '--ignore-not-found').Output | Write-Log
        
        # Delete cert-manager namespace (CRDs remain cluster-scoped)
        (Invoke-Kubectl -Params 'delete', 'namespace', 'nginx-gw-cert-manager-temp', '--ignore-not-found', '--wait=false').Output | Write-Log
        
        Write-Log 'cert-manager cleanup completed' -Console
        
        return $true
    }
    catch {
        Write-Log "Error creating TLS certificate: $_" -Error
        
        # Clean up cert-manager on failure to avoid leaving broken installation
        Write-Log 'Cleaning up cert-manager due to failure...' -Console
        try {
            $certificateYaml = "$PSScriptRoot\manifests\k2s-cluster-local-tls-certificate.yaml"
            if (Test-Path $certificateYaml) {
                (Invoke-Kubectl -Params 'delete', '-f', $certificateYaml, '--ignore-not-found').Output | Write-Log
            }
            (Invoke-Kubectl -Params 'delete', 'namespace', 'nginx-gw-cert-manager-temp', '--ignore-not-found', '--wait=false').Output | Write-Log
            Write-Log 'Cleanup completed' -Console
        }
        catch {
            Write-Log "Warning: Cleanup failed: $_" -Console
        }
        
        return $false
    }
}

Export-ModuleMember -Function Get-ExternalDnsConfigDir, Get-NginxGatewayYamlDir, Get-NginxGatewayCrdsDir, Test-SecurityAddonAvailability, New-TlsCertificateWithCertManager