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
    return "$PSScriptRoot\manifests\cert-manager.yaml"
}

function Get-CAIssuerConfig {
    return "$PSScriptRoot\manifests\ca-issuer.yaml"
}

function Get-KeyCloakConfig {
    return "$PSScriptRoot\manifests\keycloak\keycloak.yaml"
}

function Get-OAuth2ProxyConfig {
    return "$PSScriptRoot\manifests\keycloak\oauth2-proxy.yaml"
}

function Get-SecurityData {
    return "$PSScriptRoot\data"
}

function Apply-WindowsSecurityYaml {
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
            $response = & curl.exe -s -o /dev/null -w '%{http_code}' $url
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

function Apply-WindowsSecurityDeployments {
    $securityData = Get-SecurityData
    if (-Not (Test-Path $securityData)) {
        New-Item -ItemType Directory -Path $securityData -Force | Out-Null
    }

    $sqlitePath = "$securityData\db.sqlite"
    if (Test-Path $sqlitePath) {
        Remove-Item -Path $sqlitePath -Force
    }


    Write-Log 'Applying windows security deployments..' -Console
    $hydraYamlPath = "$PSScriptRoot\manifests\keycloak\hydra.yaml"
    $updatedHydraYamlPath = "$PSScriptRoot\manifests\keycloak\hydra-updated.yaml"
    Apply-WindowsSecurityYaml -yamlPath $hydraYamlPath -updatedYamlPath $updatedHydraYamlPath

    $winLoginYamlPath = "$PSScriptRoot\manifests\keycloak\windows-login.yaml"
    $updatedWinLoginYamlPath = "$PSScriptRoot\manifests\keycloak\windows-login-updated.yaml"
    Apply-WindowsSecurityYaml -yamlPath $winLoginYamlPath -updatedYamlPath $updatedWinLoginYamlPath

    Write-Log 'Waiting for windows security deployments..' -Console
    $hydraStatus = (Wait-ForPodCondition -Condition Ready -Label 'app=hydra' -Namespace 'security' -TimeoutSeconds 120)
    $winLoginStatus = (Wait-ForPodCondition -Condition Ready -Label 'app=windows-login' -Namespace 'security' -TimeoutSeconds 120)

    Write-Log 'Waiting for windows security api to be available..' -Console
    $hydraUrl = 'http://172.19.1.1:4445/admin/clients'
    $hydraApiStatus = Wait-ForHydraAvailable -url $hydraUrl

    if ($hydraApiStatus -eq $true) {
        Write-Log 'Creating client in windows security' -Console
        $response = Invoke-HydraClient -url $hydraUrl -jsonFilePath "$PSScriptRoot\manifests\keycloak\client.json"
    }    

    return ($hydraStatus -eq $true -and $winLoginStatus -eq $true -and $hydraApiStatus -eq $true)
}

function Remove-WindowsSecurityDeployments {
    $hydraYamlPath = "$PSScriptRoot\manifests\keycloak\hydra.yaml"
    (Invoke-Kubectl -Params 'delete','--ignore-not-found','-f', $hydraYamlPath).Output | Write-Log

    $winLoginYamlPath = "$PSScriptRoot\manifests\keycloak\windows-login.yaml"
    (Invoke-Kubectl -Params 'delete','--ignore-not-found','-f', $winLoginYamlPath).Output | Write-Log
}

<#
.DESCRIPTION
Writes the usage notes for security for the user.
#>
function Write-SecurityUsageForUser {
    @'
                SECURITY ADDON - EXPERIMENTAL

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
2. security: Basic authentication support is enabled. Dummy users are also created for development.
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
function Wait-ForKeyCloakAvailable {
    return (Wait-ForPodCondition -Condition Ready -Label 'app=keycloak' -Namespace 'security' -TimeoutSeconds 120)
}

<#
.DESCRIPTION
Waits for the oauth2-proxy pods to be available.
#>
function Wait-ForOauth2ProxyAvailable {
    return (Wait-ForPodCondition -Condition Ready -Label 'k8s-app=oauth2-proxy' -Namespace 'security' -TimeoutSeconds 120)
}

function Deploy-IngressForSecurity([string]$Ingress) {
    switch ($Ingress) {
        'nginx' {
            (Invoke-Kubectl -Params 'apply', '-f', "$PSScriptRoot\manifests\keycloak\nginx-ingress.yaml").Output | Write-Log
            break
        }
        'traefik' {
            (Invoke-Kubectl -Params 'apply', '-f', "$PSScriptRoot\manifests\keycloak\traefik-ingress.yaml").Output | Write-Log
            break
        }
    }
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

function Get-LinkerdConfig {
    return "$PSScriptRoot\manifests\linkerd"
}

<#
.DESCRIPTION
Waits for the linkerd pods to be available.
#>
function Wait-ForLinkerdAvailable {
    return (Wait-ForPodCondition -Condition Ready -Label 'linkerd.io/workload-ns=linkerd' -Namespace 'linkerd' -TimeoutSeconds 120)
}

<#
.DESCRIPTION
Waits for the linkerd viz pods to be available.
#>
function Wait-ForLinkerdVizAvailable {
    return (Wait-ForPodCondition -Condition Ready -Label 'linkerd.io/extension=viz' -Namespace 'linkerd-viz' -TimeoutSeconds 120)
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

function Remove-Access-ToCNIPluginFile {
    # Specify the path of the file
    $k2sConfigDir = Get-K2sConfigDir
    $filePath = $k2sConfigDir +"\cniconfig"  
    # Get the current ACL for the file
    $acl = Get-Acl $filePath
    # Define the Local System account (SYSTEM)
    $systemAccount = New-Object System.Security.Principal.NTAccount("SYSTEM")
    $currentAccount = [System.Security.Principal.WindowsIdentity]::GetCurrent()

    # Define the access rule: Full control for SYSTEM only
    $accessRuleSystem = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $systemAccount, 
        "FullControl", 
        "Allow"
    )
    # Define the access rule: Full control for current user only
    $accessRuleCurrent = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $currentAccount, 
        "FullControl", 
        "Allow"
    )
    # Deny access to everyone else
    $everyoneAccount = New-Object System.Security.Principal.NTAccount("Everyone")
    $denyRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $everyoneAccount, 
        "FullControl", 
        "Deny"
    )

    # Set access rule protection (to prevent inheritance from parent)
    $acl.SetAccessRuleProtection($true, $false)

    # Add the access rules to the ACL
    $acl.AddAccessRule($accessRuleSystem)  # Allow SYSTEM full control
    $acl.AddAccessRule($accessRuleCurrent)  # Allow SYSTEM full control
    $acl.AddAccessRule($denyRule)    # Deny Everyone access

    # Apply the updated ACL to the file
    Set-Acl -Path $filePath -AclObject $acl
} 

function Initialize-ConfigFile-For-CNI {
    # Specify the path of the file
    $k2sConfigDir = Get-K2sConfigDir
    $kubeconfigPath = $k2sConfigDir +"\cniconfig"

    # API URL
    $apiServerUrl = (Invoke-Kubectl -Params 'config', 'view', '--minify', '-o', 'jsonpath={.clusters[0].cluster.server}').Output

    # Token
    $token = (Invoke-Kubectl -Params 'create', 'token', 'cni-plugin-sa', '--namespace', 'security').Output

    # Create the kubeconfig YAML content
    $kubeconfigContent = @"
    apiVersion: v1
    kind: Config
    clusters:
    - cluster:
        server: $apiServerUrl
        certificate-authority-data: $caCert
    name: kubernetes

    contexts:
    - context:
        cluster: kubernetes
        user: service-account-user
    name: service-account-context

    current-context: service-account-context

    users:
    - name: service-account-user
    user:
        token: $token
"@

    # Write the kubeconfig content to the specified file
    $kubeconfigContent | Set-Content -Path $kubeconfigPath
}