# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$k8sApiModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k8s-api/k8s-api.module.psm1"

Import-Module $infraModule, $k8sApiModule

$cmctlExe = "$(Get-KubeBinPath)\cmctl.exe"

function Get-CAIssuerName {
    return 'K2s Self-Signed CA'
}

function Get-TrustedRootStoreLocation {
    return 'Cert:\LocalMachine\Root'
}

function Get-CertManagerConfig {
    return "$PSScriptRoot\manifests\certmanager\cert-manager.yaml"
}

function Get-CAIssuerConfig {
    return "$PSScriptRoot\manifests\certmanager\ca-issuer.yaml"
}

function Get-KeyCloakConfig {
    return "$PSScriptRoot\manifests\keycloak\keycloak.yaml"
}

function Get-KeyCloakPostgresConfig {
    return "$PSScriptRoot\manifests\keycloak\keycloak-postgres.yaml"
}

function Get-OAuth2ProxyConfig {
    return "$PSScriptRoot\manifests\keycloak\oauth2-proxy.yaml"
}

function Get-OAuth2ProxyHydraConfig {
    return "$PSScriptRoot\manifests\hydra\oauth2-proxy-hydra.yaml"
}

function Get-SecurityData {
    return "$PSScriptRoot\data"
}

function Invoke-WindowsSecurityYaml {
    param (
        [string]$yamlPath,
        [string]$updatedYamlPath
    )

    $securityData = Get-SecurityData

    if (Test-Path $updatedYamlPath) {
        Remove-Item -Path $updatedYamlPath -Force
    }

    $yamlContent = Get-Content -Path $yamlPath -Raw
    $updatedYamlContent = $yamlContent -replace '<%K2S-SECURITY-DATA%>', $securityData
    $updatedYamlContent | Set-Content -Path $updatedYamlPath -Force

    (Invoke-Kubectl -Params 'apply', '-f', $updatedYamlPath).Output | Write-Log
    Remove-Item -Path $updatedYamlPath -Force
}

function Wait-ForHydraAvailable {
    param (
        [string]$url,
        [int]$timeoutSeconds = 120,
        [int]$retryIntervalSeconds = 10
    )

    $endTime = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $endTime) {
        try {
            Write-Log "Checking Hydra availability at $url" -Console
            $response = & curl.exe -s -o /dev/null -w '%{http_code}' $url --insecure
            if ($response -eq 200) {
                Write-Log "Hydra is available at $url" -Console
                return $true
            }
        }
        catch {
            Write-Log "Hydra is not available yet. Retrying in $retryIntervalSeconds seconds..." -Console
        }
        Start-Sleep -Seconds $retryIntervalSeconds
    }
    Write-Log "Hydra did not become available within the timeout period of $timeoutSeconds seconds." -Console
    return $false
}

function Invoke-HydraClient {
    param (
        [string]$url,
        [string]$jsonFilePath
    )

    if (-Not (Test-Path $jsonFilePath)) {
        Write-Log "JSON file not found at $jsonFilePath" -Console
        return $false
    }

    $jsonContent = Get-Content -Path $jsonFilePath -Raw
    try {
        $response = Invoke-RestMethod -Uri $url -Method Post -ContentType 'application/json' -Body $jsonContent
        Write-Log "POST request to $url was successful." -Console
        return $response
    }
    catch {
        Write-Log "POST request to $url failed: $_" -Console
        return $false
    }
}

function Enable-WindowsSecurityDeployments {
    $securityData = Get-SecurityData
    if (-Not (Test-Path $securityData)) {
        New-Item -ItemType Directory -Path $securityData -Force | Out-Null
    }

    $sqlitePath = "$securityData\db.sqlite"
    if (Test-Path $sqlitePath) {
        Remove-Item -Path $sqlitePath -Force
    }


    Write-Log 'Applying windows security deployments..' -Console
    $hydraYamlPath = "$PSScriptRoot\manifests\keycloak\windowsprovider\hydra.yaml"
    $updatedHydraYamlPath = "$PSScriptRoot\manifests\keycloak\windowsprovider\hydra-updated.yaml"
    Invoke-WindowsSecurityYaml -yamlPath $hydraYamlPath -updatedYamlPath $updatedHydraYamlPath

    $winLoginYamlPath = "$PSScriptRoot\manifests\keycloak\windowsprovider\windows-login.yaml"
    $updatedWinLoginYamlPath = "$PSScriptRoot\manifests\keycloak\windowsprovider\windows-login-updated.yaml"
    Invoke-WindowsSecurityYaml -yamlPath $winLoginYamlPath -updatedYamlPath $updatedWinLoginYamlPath

    Write-Log 'Waiting for windows security deployments..' -Console
    $hydraStatus = (Wait-ForPodCondition -Condition Ready -Label 'app=hydra' -Namespace 'security' -TimeoutSeconds 120)
    $winLoginStatus = (Wait-ForPodCondition -Condition Ready -Label 'app=windows-login' -Namespace 'security' -TimeoutSeconds 120)

    Write-Log 'Waiting for windows security api to be available..' -Console
    $hydraUrl = 'http://172.19.1.1:4445/admin/clients'
    $hydraApiStatus = Wait-ForHydraAvailable -url $hydraUrl

    if ($hydraApiStatus -eq $true) {
        Write-Log 'Creating client in windows security' -Console
        $response = Invoke-HydraClient -url $hydraUrl -jsonFilePath "$PSScriptRoot\manifests\keycloak\windowsprovider\client.json"
    }    

    return ($hydraStatus -eq $true -and $winLoginStatus -eq $true -and $hydraApiStatus -eq $true)
}

function Remove-WindowsSecurityDeployments {
    $hydraYamlPath = "$PSScriptRoot\manifests\keycloak\windowsprovider\hydra.yaml"
    (Invoke-Kubectl -Params 'delete', '--ignore-not-found', '-f', $hydraYamlPath).Output | Write-Log

    $winLoginYamlPath = "$PSScriptRoot\manifests\keycloak\windowsprovider\windows-login.yaml"
    (Invoke-Kubectl -Params 'delete', '--ignore-not-found', '-f', $winLoginYamlPath).Output | Write-Log
}

<#
.DESCRIPTION
Writes the usage notes for security for the user.
#>
function Write-SecurityUsageForUser {
    @'
                SECURITY ADDON

The following features are available:
1. cert-manager: The CA Issuer named 'k2s-ca-issuer' has beed created and can 
   be used for signing. Example usage:
   ---
   apiVersion: networking.k8s.io/v1
   kind: Ingress
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
   ---
2. keycloak: Authentication support is enabled. Dummy users are also created for development.
   user: demo-user
   password: password
   Add below annotations in ingress to enable authentication support.
    nginx.ingress.kubernetes.io/auth-url: "https://k2s.cluster.local/oauth2/auth"
    nginx.ingress.kubernetes.io/auth-signin: "https://k2s.cluster.local/oauth2/start?rd=$escaped_request_uri"
    nginx.ingress.kubernetes.io/auth-response-headers: "Authorization"
   To access keycloak admin ui: https://k2s.cluster.local/keycloak/
        user: admin
        password: admin
   Refer https://www.keycloak.org/guides for more information about keycloak
3. linkerd (only for enhanced security type): Linkerd is a service mesh implementation. It adds security, observability, and reliability to any Kubernetes cluster.
   If you have choosen the enhanced security mode, than linkerd is enabled.
   Add below annotations in your workload to enable linkerd support.
    linkerd.io/inject: "enabled"
   For more information on how to use linkerd please check: https://linkerd.io/2-edge/overview/
   To start the linkerd dashboard please run 'linkerd viz install | kubectl apply -f -' and the afterwards pods are running run 'linkerd viz dashboard --port 60888 &'
This addon is documented in <installation folder>\addons\security\README.md
'@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
}

function Write-SecurityWarningForUser {
    @'

                ATTENTION:
If you disable this add-on, the sites protected by cert-manager certificates 
will become untrusted. Delete the HSTS settings for your site (e.g. 'k2s.cluster.local')
here (works in Chrome and Edge):
chrome://net-internals/#hsts
  
'@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
}

<#
.DESCRIPTION
Waits for the cert-manager API to be available.
#>
function Wait-ForCertManagerAvailable {
    $out = &$cmctlExe check api --wait=3m
    if ($out -match 'The cert-manager API is ready') {
        return $true
    }
    return $false
}

<#
.DESCRIPTION
Marks all cert-manager Certificate resources for renewal.
#>
function Update-CertificateResources {
    &$cmctlExe renew --all --all-namespaces
}

<#
.DESCRIPTION
Waits for the kubernetes secret 'ca-issuer-root-secret' in the namespace 'cert-manager' to be created.
#>
function Wait-ForCARootCertificate(
    [int]$SleepDurationInSeconds = 10,
    [int]$NumberOfRetries = 10) {
    for (($i = 1); $i -le $NumberOfRetries; $i++) {
        $out = (Invoke-Kubectl -Params '-n', 'cert-manager', 'get', 'secrets', 'ca-issuer-root-secret', '-o=jsonpath="{.metadata.name}"', '--ignore-not-found').Output
        if ($out -match 'ca-issuer-root-secret') {
            Write-Log "'ca-issuer-root-secret' created and ready for use."
            return $true
        }
        Write-Log "Retry {$i}: 'ca-issuer-root-secret' not yet created. Will retry after $SleepDurationInSeconds Seconds" -Console
        Start-Sleep -Seconds $SleepDurationInSeconds
    }
    return $false
}

function Remove-Cmctl {
    Write-Log "Removing $cmctlExe.."
    Remove-Item -Path $cmctlExe -Force -ErrorAction SilentlyContinue
}

<#
.DESCRIPTION
Waits for the keycloak pods to be available.
#>
function Wait-ForKeyCloakAvailable($waiTime = 120) {
    return (Wait-ForPodCondition -Condition Ready -Label 'app=keycloak' -Namespace 'security' -TimeoutSeconds $waiTime)
}

<#
.DESCRIPTION
Waits for the keycloak postgresqlpods to be available.
#>
function Wait-ForKeyCloakPostgresqlAvailable($waiTime = 120) {
    return (Wait-ForPodCondition -Condition Ready -Label 'app=postgresql' -Namespace 'security' -TimeoutSeconds $waiTime)
}

<#
.DESCRIPTION
Waits for the oauth2-proxy pods to be available.
#>
function Wait-ForOauth2ProxyAvailable {
    return (Wait-ForPodCondition -Condition Ready -Label 'k8s-app=oauth2-proxy' -Namespace 'security' -TimeoutSeconds 120)
}

<#
.DESCRIPTION
Tests if the OAuth2 proxy service is available.
#>
function Test-OAuth2ProxyServiceAvailability {
    $deployment = (Invoke-Kubectl -Params '-n', 'security', 'get', 'deployment', 'oauth2-proxy', '--ignore-not-found').Output
    return $deployment -and $deployment -notmatch 'NotFound'
}

function Enable-IngressForSecurity([string]$Ingress) {
    switch ($Ingress) {
        'nginx' {
            (Invoke-Kubectl -Params 'apply', '-f', "$PSScriptRoot\manifests\keycloak\nginx-ingress.yaml").Output | Write-Log
            break
        }
        'traefik' {
            (Invoke-Kubectl -Params 'apply', '-f', "$PSScriptRoot\manifests\keycloak\traefik-ingress.yaml").Output | Write-Log
            break
        }
        'nginx-gw' {
            (Invoke-Kubectl -Params 'apply', '-f', "$PSScriptRoot\manifests\keycloak\nginx-gw-ingress.yaml").Output | Write-Log
            break
        }
    }
}

function Remove-IngressForSecurity {
    (Invoke-Kubectl -Params 'delete', '-f', "$PSScriptRoot\manifests\keycloak\nginx-ingress.yaml", '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', '-f', "$PSScriptRoot\manifests\keycloak\traefik-ingress.yaml", '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', '-f', "$PSScriptRoot\manifests\keycloak\nginx-gw-ingress.yaml", '--ignore-not-found').Output | Write-Log
}

function Confirm-EnhancedSecurityOn([string]$Type) {
    # check content of string
    if ($Type -eq 'enhanced') {
        return $true
    }
    return $false
}

function Get-EnhancedSecurityFileLocation {
    return "$env:ProgramData\\K2s\\enhancedsecurity.json"
}

function Get-LinkerdConfigDirectory {
    return "$PSScriptRoot\manifests\linkerd"
}

function Get-LinkerdConfigCRDs {
    return "$PSScriptRoot\manifests\linkerd\linkerd-crds.yaml"
}

function Get-LinkerdConfigTrustManager {
    return "$PSScriptRoot\manifests\linkerd\trust-manager.yaml"
}

function Get-LinkerdConfigCertManager {
    return "$PSScriptRoot\manifests\linkerd\linkerd-cert-manager.yaml"
}

function Get-LinkerdConfigCNI {
    return "$PSScriptRoot\manifests\linkerd\linkerd-cni-plugin-sa.yaml"
}

<#
.DESCRIPTION
Waits for the linkerd pods to be available.
#>
function Wait-ForLinkerdAvailable {
    return (Wait-ForPodCondition -Condition Ready -Label 'linkerd.io/workload-ns=linkerd' -Namespace 'linkerd' -TimeoutSeconds 180)
}

<#
.DESCRIPTION
Waits for the linkerd viz pods to be available.
#>
function Wait-ForLinkerdVizAvailable {
    return (Wait-ForPodCondition -Condition Ready -Label 'linkerd.io/extension=viz' -Namespace 'linkerd-viz' -TimeoutSeconds 120)
}

function Wait-ForTrustManagerAvailable($waiTime = 120) {
    return (Wait-ForPodCondition -Condition Ready -Label 'app.kubernetes.io/name=trust-manager' -Namespace 'cert-manager' -TimeoutSeconds $waiTime)
}

function Wait-ForTrustManagerWebhookReady {
    <#
    .SYNOPSIS
    Waits for trust-manager webhook to be ready to accept requests.
    .DESCRIPTION
    After trust-manager pods are ready, the webhook endpoint may still need additional time
    to become available. This function retries creating a test Bundle resource to verify
    webhook readiness before proceeding with actual cert-manager resource creation.
    .PARAMETER MaxRetries
    Maximum number of retry attempts (default: 10)
    .PARAMETER RetryDelaySeconds
    Delay between retries in seconds (default: 3)
    #>
    param(
        [int]$MaxRetries = 10,
        [int]$RetryDelaySeconds = 3
    )

    Write-Log "Waiting for trust-manager webhook to be ready (max retries: $MaxRetries)" -Console

    $testBundleYaml = @"
apiVersion: trust.cert-manager.io/v1alpha1
kind: Bundle
metadata:
  name: trust-manager-webhook-test
spec:
  sources:
  - useDefaultCAs: true
  target:
    configMap:
      key: trust-bundle.pem
"@

    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        $testBundleYaml | Out-File -FilePath $tempFile -Encoding UTF8 -Force

        for ($i = 1; $i -le $MaxRetries; $i++) {
            Write-Log "Webhook readiness check attempt $i of $MaxRetries"
            
            # Try to create the test bundle
            $result = Invoke-Kubectl -Params 'apply', '-f', $tempFile
            
            if ($result.Success) {
                Write-Log "Trust-manager webhook is ready" -Console
                # Clean up test bundle
                $null = Invoke-Kubectl -Params 'delete', '-f', $tempFile, '--ignore-not-found=true'
                return $true
            }
            
            # Check if error is webhook-related
            if ($result.Output -match 'failed calling webhook.*trust\.cert-manager\.io|connection refused|timeout') {
                Write-Log "Webhook not ready yet (attempt $i): connection issue detected. Waiting ${RetryDelaySeconds}s..."
                if ($i -lt $MaxRetries) {
                    Start-Sleep -Seconds $RetryDelaySeconds
                    continue
                }
            } else {
                # Different error - may be a real problem
                Write-Log "Unexpected error during webhook check: $($result.Output)" -Console
                return $false
            }
        }

        Write-Log "Trust-manager webhook did not become ready after $MaxRetries attempts" -Console
        return $false
    }
    finally {
        # Clean up temp file and test bundle
        if (Test-Path $tempFile) {
            Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
        }
        $null = Invoke-Kubectl -Params 'delete', 'bundle', 'trust-manager-webhook-test', '--ignore-not-found=true'
    }
}

function Save-LinkerdMarkerConfig {
    # write info file for enhanced security
    $jsonFile = Get-EnhancedSecurityFileLocation
    $json = "{`"SecurityType`":`"$Type`"}"
    $json | Out-File -FilePath $jsonFile     
}

function Remove-LinkerdMarkerConfig {
    # write info file for enhanced security
    $jsonFile = Get-EnhancedSecurityFileLocation
    if (Test-Path $jsonFile) {
        Remove-Item -Path $jsonFile -Force
    } 
}
function Remove-LinkerdExecutable {
    $binPath = Get-KubeBinPath
    if (Test-Path "$binPath\linkerd.exe") {
        Remove-Item -Path "$binPath\linkerd.exe" -Force
    }
}

function Remove-LinkerdManifests {
    $fileToRemove = "$PSScriptRoot\manifests\linkerd\linkerd.yaml"
    if (Test-Path $fileToRemove) {
        Remove-Item -Path $fileToRemove -Force
    }
    $fileToRemove = "$PSScriptRoot\manifests\linkerd\linkerd-crds.yaml"
    if (Test-Path $fileToRemove) {
        Remove-Item -Path $fileToRemove -Force
    }
}

# function Remove-Access-ToCNIPluginFile {
#     # Specify the path of the file
#     $k2sConfigDir = Get-K2sConfigDir
#     $filePath = $k2sConfigDir +"\cniconfig"  
#     # Get the current ACL for the file
#     $acl = Get-Acl $filePath
#     # Define the Local System account (SYSTEM)
#     $systemAccount = New-Object System.Security.Principal.NTAccount("SYSTEM")
#     $currentAccount = [System.Security.Principal.WindowsIdentity]::GetCurrent()

#     # Define the access rule: Full control for SYSTEM only
#     $accessRuleSystem = New-Object System.Security.AccessControl.FileSystemAccessRule(
#         $systemAccount, 
#         "FullControl", 
#         "Allow"
#     )
#     # Define the access rule: Full control for current user only
#     $accessRuleCurrent = New-Object System.Security.AccessControl.FileSystemAccessRule(
#         $currentAccount, 
#         "FullControl", 
#         "Allow"
#     )
#     # Deny access to everyone else
#     $everyoneAccount = New-Object System.Security.Principal.NTAccount("Everyone")
#     $denyRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
#         $everyoneAccount, 
#         "FullControl", 
#         "Deny"
#     )

#     # Set access rule protection (to prevent inheritance from parent)
#     $acl.SetAccessRuleProtection($true, $false)

#     # Add the access rules to the ACL
#     $acl.AddAccessRule($accessRuleSystem)  # Allow SYSTEM full control
#     $acl.AddAccessRule($accessRuleCurrent)  # Allow SYSTEM full control
#     $acl.AddAccessRule($denyRule)    # Deny Everyone access

#     # Apply the updated ACL to the file
#     Set-Acl -Path $filePath -AclObject $acl
# } 

function Initialize-ConfigFileForCNI {
    # Variables
    $secretName = 'cni-plugin-token'
    $kubeconfigPath = 'C:\Windows\System32\config\systemprofile\config'

    # API URL
    $apiServerUrl = (Invoke-Kubectl -Params 'config', 'view', '--minify', '-o', 'jsonpath={.clusters[0].cluster.server}').Output

    # Fetch the secret
    $secret = (Invoke-Kubectl -Params 'get', 'secret', $secretName, '--namespace', 'security', '-o', 'json').Output | ConvertFrom-Json

    # Decode base64 token and CA cert
    $token = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($secret.data.token))
    $caCert = $secret.data.'ca.crt'

    $clusterName = Get-InstalledClusterName

    # Create the kubeconfig YAML content
    $kubeconfigContent = @"
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: $apiServerUrl
    certificate-authority-data: $caCert
  name: $clusterName

contexts:
- context:
    cluster: $clusterName
    user: cni-plugin-sa
    namespace: security
  name: service-account-context

current-context: service-account-context

users:
- name: cni-plugin-sa
  user:
      token: $token
"@

    # Write the kubeconfig content to the specified file
    $kubeconfigContent | Set-Content -Path $kubeconfigPath
}

function Remove-ConfigFileForCNI {
    $kubeconfigPath = 'C:\Windows\System32\config\systemprofile\config'
    if (Test-Path $kubeconfigPath) {
        Remove-Item -Path $kubeconfigPath -Force
    }
}

function Wait-ForK8sSecret {
    param (
        [Parameter(Mandatory = $true)]
        [string]$SecretName,
        [Parameter(Mandatory = $true)]
        [string]$Namespace,
        [int]$TimeoutSeconds = 60,
        [int]$CheckIntervalSeconds = 4
    )

    $startTime = Get-Date
    $endTime = $startTime.AddSeconds($TimeoutSeconds)

    $kubeToolsPath = Get-KubeToolsPath
    while ((Get-Date) -lt $endTime) {
        try {
            $secret = &"$kubeToolsPath\kubectl.exe" get secret $SecretName -n $Namespace --ignore-not-found
            if ($secret) {
                Write-Log "Secret '$SecretName' is available." -Console
                return $true
            }
        }
        catch {
            Write-Log "Error checking for secret: $_" -Console
        }

        Start-Sleep -Seconds $CheckIntervalSeconds
    }

    Write-Log "Timed out waiting for secret '$SecretName' in namespace '$Namespace'." -Console
    return $false
}