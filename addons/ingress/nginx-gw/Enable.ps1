# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs nginx-gw - kubernetes gateway api controller(gateway controller)

.DESCRIPTION
NA

.EXAMPLE
# For k2sSetup.
powershell <installation folder>\addons\ingress\nginx-gw\Enable.ps1
#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$infraModule = "$PSScriptRoot/../../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"
$gatewayModule = "$PSScriptRoot\nginx-gw.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule, $gatewayModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Checking cluster status' -Console

# get addon name from folder path
$addonName = Get-AddonNameFromFolderPath -BaseFolderPath $PSScriptRoot

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

$setupInfo = Get-SetupInfo
if ($setupInfo.Name -ne 'k2s') {
    $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon 'ingress nginx-gw' can only be enabled for 'k2s' setup type."  
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'ingress'; Implementation = 'nginx-gw' })) -eq $true) {
    $errMsg = "Addon 'ingress nginx-gw' is already enabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'ingress'; Implementation = 'nginx' })) -eq $true) {
    $errMsg = "Addon 'ingress nginx' is enabled. Disable it first to avoid port conflicts."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}


if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'ingress'; Implementation = 'traefik' })) -eq $true) {
    $errMsg = "Addon 'ingress traefik' is enabled. Disable it first to avoid port conflicts."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'gateway-api' })) -eq $true) {
    $errMsg = "Addon 'gateway-api' is enabled. Disable it first to avoid port conflicts."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$existingServices = (Invoke-Kubectl -Params 'get', 'service', '-n', 'nginx-gw-controller', '-o', 'yaml').Output
if ("$existingServices" -match '.*nginx-gw.*') {
    $errMsg = 'It seems as if ingress nginx gateway is already installed in the namespace nginx-gw. Disable it before enabling it again.'
    
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Installing ExternalDNS' -Console
$externalDnsConfig = Get-ExternalDnsConfigDir
(Invoke-Kubectl -Params 'apply' , '-k', $externalDnsConfig).Output | Write-Log

$kustomization = @"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- ../manifests
"@

#create a temporary directory to store the kustomization file
$kustomizationDir = "$PSScriptRoot/kustomizationDir"
New-Item -Path $kustomizationDir -ItemType 'directory' -ErrorAction SilentlyContinue
$kustomizationFile = "$kustomizationDir\kustomization.yaml"
$kustomization | Out-File $kustomizationFile

Write-Log 'Installing nginx gateway' -Console
$ingressNginxGatewayNamespace = 'nginx-gw'

# Apply NGF CRDs first using server-side apply to avoid oversized
# last-applied annotations on large CRDs
$CrdsDirectory = Get-NginxGatewayCrdsDir
(Invoke-Kubectl -Params 'apply', '--server-side', '-f', $CrdsDirectory).Output | Write-Log

(Invoke-Kubectl -Params 'apply' , '-k', $kustomizationDir).Output | Write-Log

# # delete the temporary directory
Remove-Item -Path $kustomizationDir -Recurse

$controlPlaneIp = Get-ConfiguredIPControlPlane

# Apply NginxProxy resource with the control plane IP configured
Write-Log "Preparing NginxProxy resource with external IP $controlPlaneIp" -Console
$nginxProxyTemplate = Get-Content "$PSScriptRoot\manifests\nginxproxy.yaml" -Raw
$nginxProxyYaml = $nginxProxyTemplate.Replace('__CONTROL_PLANE_IP__', $controlPlaneIp)
$nginxProxyYaml | & kubectl apply -f -

$allPodsAreUp = (Wait-ForPodCondition -Condition Ready -Label 'app.kubernetes.io/component=controller' -Namespace 'nginx-gw' -TimeoutSeconds 300)

 if ($allPodsAreUp -ne $true) {
    $errMsg = "All ingress nginx pods could not become ready. Please use kubectl describe for more details.`nInstallation of ingress nginx failed."
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

# Check if cert-manager is running (security addon provides cert-manager)
$certManagerRunning = $false
$certManagerPods = (Invoke-Kubectl -Params 'get', 'pods', '-n', 'cert-manager', '--ignore-not-found').Output
if (-not [string]::IsNullOrWhiteSpace($certManagerPods)) {
    $certManagerRunning = $true
    Write-Log 'cert-manager detected - will use managed certificates' -Console
}

# Create self-signed TLS certificate only if cert-manager is not running and secret doesn't exist
$secretExists = (Invoke-Kubectl -Params 'get', 'secret', 'k2s-cluster-local-tls', '-n', $ingressNginxGatewayNamespace, '--ignore-not-found').Output
if ([string]::IsNullOrWhiteSpace($secretExists) -and -not $certManagerRunning) {
    Write-Log 'Creating self-signed TLS certificate for k2s.cluster.local' -Console
    
    # Generate self-signed certificate
    $certPath = [System.IO.Path]::GetTempPath() + 'k2s-gw-cert.pem'
    $keyPath = [System.IO.Path]::GetTempPath() + 'k2s-gw-key.pem'
    
    # Use OpenSSL to generate self-signed cert (openssl should be available on Windows)
    $opensslCmd = "openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout `"$keyPath`" -out `"$certPath`" -subj `"/CN=k2s.cluster.local`" 2>&1"
    $opensslResult = Invoke-Expression $opensslCmd
    
    if (Test-Path $certPath) {
        # Create Kubernetes TLS secret
        (Invoke-Kubectl -Params 'create', 'secret', 'tls', 'k2s-cluster-local-tls', '--cert', $certPath, '--key', $keyPath, '-n', $ingressNginxGatewayNamespace).Output | Write-Log
        
        # Clean up temp files
        Remove-Item -Path $certPath -ErrorAction SilentlyContinue
        Remove-Item -Path $keyPath -ErrorAction SilentlyContinue
        
        Write-Log 'Self-signed TLS certificate created successfully' -Console
    } else {
        Write-Log 'Warning: Could not create self-signed certificate. HTTPS may not work until certificate is provided.' -Console
    }
} elseif ($certManagerRunning) {
    Write-Log 'TLS certificate will be managed by cert-manager' -Console
} else {
    Write-Log 'TLS certificate already exists' -Console
}

# Now create the Gateway resource which will use the patched NginxProxy configuration
Write-Log 'Creating Gateway resource' -Console
$clusterIngressConfig = "$PSScriptRoot\manifests\cluster-local-nginx-gw.yaml"
(Invoke-Kubectl -Params 'apply' , '-f', $clusterIngressConfig).Output | Write-Log

# Wait for controller to reconcile and create data plane service with external IP
Write-Log 'Waiting for data plane service to be created with external IP...' -Console
Start-Sleep -Seconds 5

Write-Log 'All nginx gateway pods are up and ready.'

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'ingress'; Implementation = 'nginx-gw' })

&"$PSScriptRoot\Update.ps1"

# adapt other addons
Update-Addons -AddonName $addonName

Write-Log 'nginx-gw installed successfully' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}