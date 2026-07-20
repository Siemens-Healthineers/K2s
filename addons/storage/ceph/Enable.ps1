# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Enables Ceph CSI storage provisioner addon

.DESCRIPTION
Deploys Ceph CSI operator components for CephFS (file) provisioning to enable
dynamic storage provisioning for Ceph clusters without Rook operator.

.PARAMETER ShowLogs
If log output shall be streamed also to CLI output.

.PARAMETER MonitorEndpoints
Ceph monitor endpoints (comma-separated, e.g., "10.0.0.1:6789,10.0.0.2:6789")

.PARAMETER AdminKey
Base64-encoded Ceph admin keyring

.PARAMETER CephfsPool
CephFS data pool name (default: cephfs_data)
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Ceph monitor endpoints (comma-separated)')]
    [string] $MonitorEndpoints,
    [parameter(Mandatory = $false, HelpMessage = 'Base64-encoded Ceph admin keyring')]
    [string] $AdminKey,
    [parameter(Mandatory = $false, HelpMessage = 'CephFS data pool name')]
    [string] $CephfsPool = 'cephfs_data',
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceding parameters')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$script = $MyInvocation.MyCommand.Name
$infraModule = "$PSScriptRoot/../../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"
$validationModule = "$PSScriptRoot\..\storage-validation.module.psm1"
Import-Module $infraModule, $clusterModule, $addonsModule, $validationModule

Initialize-Logging -ShowLogs:$ShowLogs

# get addon name from folder path
$addonName = Get-AddonNameFromFolderPath -BaseFolderPath $PSScriptRoot

# Validate no conflicting storage implementation is enabled
$conflictError = Test-ConflictingStorageImplementation -RequestedImplementation 'ceph'
if ($conflictError) {
    Write-Log "[$script] ERROR: $conflictError" -Console -Error
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = (New-Error -Code 'storage-conflict' -Message $conflictError) }
        return
    }
    exit 1
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = $AddonName })) -eq $true) {
    $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message "Addon '$AddonName' is already enabled, nothing to do." 
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
  }
  Write-Log $err.Message -Error
  exit 1
}

$setupInfo = Get-SetupInfo

if ($setupInfo.Name -ne 'k2s') {
    $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon '$AddonName' can only be enabled for 'k2s' setup type."  
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
  }
  Write-Log $err.Message -Error
  exit 1
}

Write-Log "[Ceph] Enabling Ceph storage addon" -Console


function Convert-ToYamlSingleQuoted {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Value
  )

  return "'" + ($Value -replace "'", "''") + "'"
}

function New-CephStructuredError {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  return (New-Error -Code 'addon-enable-failed' -Message $Message)
}

function Write-CephUsageForUser {
  param(
    [Parameter(Mandatory = $false)]
    [string]$MonitorEndpoints = '',
    [Parameter(Mandatory = $false)]
    [string]$CephfsFilesystem = '',
    [Parameter(Mandatory = $false)]
    [string]$CephfsPool = '',
    [Parameter(Mandatory = $false)]
    [string]$ClusterId = '',
    [Parameter(Mandatory = $false)]
    [string]$DashboardUrl = '',
    [Parameter(Mandatory = $false)]
    [string]$DashboardUser = '',
    [Parameter(Mandatory = $false)]
    [string]$DashboardPassword = ''
  )

  @"

                                        USAGE NOTES
 The Ceph CSI storage addon is enabled. Dynamic CephFS provisioning is available
 through the following Kubernetes StorageClass:

     StorageClass:      ceph-cephfs
     Provisioner:       cephfs.csi.ceph.com
     Monitor endpoints: $MonitorEndpoints
     CephFS filesystem: $CephfsFilesystem
     CephFS pool:       $CephfsPool
     Cluster ID:        $ClusterId

 To use it, reference the StorageClass in a PersistentVolumeClaim, for example:

     apiVersion: v1
     kind: PersistentVolumeClaim
     metadata:
       name: my-cephfs-pvc
     spec:
       accessModes:
         - ReadWriteMany
       storageClassName: ceph-cephfs
       resources:
         requests:
           storage: 1Gi

 Inspect the provisioner workloads with:
     kubectl get pods -n $cephOperatorNamespace
"@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }

  if (-not [string]::IsNullOrWhiteSpace($DashboardUrl)) {
    @"

                                     CEPH DASHBOARD
 A new Ceph cluster was provisioned. The Ceph dashboard is available at:

     URL:      $DashboardUrl
     User:     $DashboardUser
     Password: $DashboardPassword

 Store these credentials securely and change the password after first login.

                                     CEPH CLI ACCESS
 On the Ceph host node you can access the Ceph CLI as follows.

 In case of multi-cluster or non-default config:

     sudo cephadm shell --fsid $ClusterId -c /etc/ceph/ceph.conf -k /etc/ceph/ceph.client.admin.keyring

 Or, if you are only running a single cluster on this host:

     sudo cephadm shell

 Cluster configuration is saved on the host under:

     /var/lib/ceph/$ClusterId/config

 Optionally, enable telemetry to help improve Ceph (see
 https://docs.ceph.com/en/latest/mgr/telemetry/):

     ceph telemetry on
"@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
  }
}

function Get-CephOperatorNamespace {
  param(
    [Parameter(Mandatory = $true)]
    [string]$OperatorManifestPath
  )

  if (-not (Test-Path $OperatorManifestPath)) {
    throw "Ceph operator manifest not found at '$OperatorManifestPath'"
  }

  $manifestContent = Get-Content -Path $OperatorManifestPath -Raw
  $namespacePattern = '(?ms)^kind:\s*Namespace\s*$.*?^metadata:\s*$.*?^\s*name:\s*(?<namespace>[A-Za-z0-9-]+)\s*$'
  $match = [regex]::Match($manifestContent, $namespacePattern)

  if (-not $match.Success) {
    throw "Failed to derive Ceph operator namespace from '$OperatorManifestPath'"
  }

  return $match.Groups['namespace'].Value
}

function Read-ValidateStorageConfig {
param (
		[pscustomobject]$Config
	)
# Defaults are stored in the script scope so they are visible to the rest of the
# script after this function returns. Only initialize when not already set.
if (-not $script:cephUser) { $script:cephUser = 'client.admin' }
if (-not $script:clusterId) { $script:clusterId = 'k2s-ceph' }
if (-not $script:cephfsFilesystem) { $script:cephfsFilesystem = 'cephfs' }

if ($null -ne $Config) {
  if (-not [string]::IsNullOrWhiteSpace($Config.monitorEndpoints)) {
    Write-Log "[Ceph] Using monitor endpoints from addon config" -Console
    $script:MonitorEndpoints = $Config.monitorEndpoints
  }

  if (-not [string]::IsNullOrWhiteSpace($Config.cephKey)) {
    Write-Log "[Ceph] Using ceph key from addon config" -Console
    $script:AdminKey = $Config.cephKey
  }

  if (-not [string]::IsNullOrWhiteSpace($Config.cephfsPool)) {
    Write-Log "[Ceph] Using CephFS pool '$($Config.cephfsPool)' from addon config" -Console
    $script:CephfsPool = $Config.cephfsPool
  }

  if (-not [string]::IsNullOrWhiteSpace($Config.cephUser)) {
    $script:cephUser = $Config.cephUser
  }

  if (-not [string]::IsNullOrWhiteSpace($Config.clusterId)) {
    $script:clusterId = $Config.clusterId
  }

  if (-not [string]::IsNullOrWhiteSpace($Config.cephfsFilesystem)) {
    $script:cephfsFilesystem = $Config.cephfsFilesystem
  }

}

Write-Log "[Ceph] Validating Ceph configuration" -Console

if (-not $script:MonitorEndpoints) {
    Write-Log "[Ceph] ERROR: Monitor endpoints are required. Provide via --monitorEndpoints flag or config file" -Console -Error
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "Monitor endpoints required") }
    }
    exit 1
}

if (-not $script:AdminKey) {
    Write-Log "[Ceph] ERROR: Admin keyring is required. Provide via --adminKey flag or config file" -Console -Error
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "Admin keyring required") }
    }
    exit 1
}

$script:AdminKey = $script:AdminKey.Trim()
if ([string]::IsNullOrWhiteSpace($script:AdminKey)) {
  Write-Log "[Ceph] ERROR: Admin keyring resolved to empty value after trimming" -Console -Error
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "Admin keyring resolved to empty value") }
  }
  exit 1
}

if ([string]::IsNullOrWhiteSpace($script:CephfsPool)) {
  Write-Log "[Ceph] ERROR: CephFS pool is required. Provide via --cephfsPool flag or 'cephfsPool' in ceph-config.json" -Console -Error
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "CephFS pool required") }
  }
  exit 1
}

Write-Log "[Ceph] Monitor endpoints: $script:MonitorEndpoints" -Console
Write-Log "[Ceph] CephFS pool: $script:CephfsPool" -Console
Write-Log "[Ceph] Ceph user: $script:cephUser" -Console
Write-Log "[Ceph] Ceph cluster ID: $script:clusterId" -Console
Write-Log "[Ceph] CephFS filesystem: $script:cephfsFilesystem" -Console
}

# When the CLI does not pass a -Config object, fall back to the addon config file
# so the documented 'edit ceph-config.json then enable' workflow works.
if ($null -eq $Config) {
  $cephConfigPath = "$PSScriptRoot\config\ceph-config.json"
  if (Test-Path $cephConfigPath) {
    Write-Log "[Ceph] Loading configuration from $cephConfigPath" -Console
    try {
      $Config = Get-Content -Path $cephConfigPath -Raw | ConvertFrom-Json
    }
    catch {
      Write-Log "[Ceph] ERROR: Failed to parse ceph-config.json: $($_.Exception.Message)" -Console -Error
      if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "Failed to parse ceph-config.json") }
      }
      exit 1
    }
  }
}


# Determine how the Ceph cluster is provided. 'existing' (default) connects to an
# already-running Ceph cluster using the values validated below and continues with the
# CSI installation. Any other value provisions a NEW Ceph cluster on the target node
# (clusterHostNodeIp), dispatching to the OS-specific creation script selected by
# clusterDistribution, before continuing with the CSI installation.
$clusterMode = 'existing'
if ($Config -and ($Config.PSObject.Properties.Name -contains 'clusterMode')) {
  $clusterMode = "$($Config.clusterMode)".Trim()
}
if ([string]::IsNullOrWhiteSpace($clusterMode)) { $clusterMode = 'existing' }

# For an existing Ceph cluster, validate the supplied connection config now. For a new cluster the
# config holds placeholder values until provisioning completes, so validation is deferred until
# after the cluster has been created (below).
if ($clusterMode -eq 'existing') {
  Read-ValidateStorageConfig -Config $Config
}

if ($clusterMode -ne 'existing') {
  Write-Log "[Ceph] clusterMode='$clusterMode' - a new Ceph cluster will be provisioned before CSI installation" -Console

  $clusterHostNodeIp = "$($Config.clusterHostNodeIp)".Trim()
  $clusterDistribution = "$($Config.clusterDistribution)".Trim().ToLowerInvariant()

  if ([string]::IsNullOrWhiteSpace($clusterHostNodeIp)) {
    Write-Log "[Ceph] ERROR: 'clusterHostNodeIp' is required in ceph-config.json when clusterMode is not 'existing'." -Console -Error
    if ($EncodeStructuredOutput -eq $true) {
      Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message 'clusterHostNodeIp is required for new Ceph cluster creation') }
    }
    exit 1
  }
  if ([string]::IsNullOrWhiteSpace($clusterDistribution)) {
    Write-Log "[Ceph] ERROR: 'clusterDistribution' is required in ceph-config.json when clusterMode is not 'existing'." -Console -Error
    if ($EncodeStructuredOutput -eq $true) {
      Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message 'clusterDistribution is required for new Ceph cluster creation') }
    }
    exit 1
  }

  # Select the OS-specific new-cluster creation script from clusterDistribution.
  # Debian 12 and Debian 13 share the same distribution-neutral scripts under scripts\linux\debian.
  $newClusterScript = $null
  switch -Regex ($clusterDistribution) {
    '^debian' { $newClusterScript = "$PSScriptRoot\scripts\linux\debian\New-CephCluster.ps1" }
    default {
      Write-Log "[Ceph] ERROR: Unsupported clusterDistribution '$clusterDistribution'. Supported values: windows, debian12, debian13." -Console -Error
      if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "Unsupported clusterDistribution '$clusterDistribution'") }
      }
      exit 1
    }
  }

  if (-not (Test-Path $newClusterScript)) {
    Write-Log "[Ceph] ERROR: New Ceph cluster creation script not found at '$newClusterScript'." -Console -Error
    if ($EncodeStructuredOutput -eq $true) {
      Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "New Ceph cluster creation script not found for distribution '$clusterDistribution'") }
    }
    exit 1
  }

  Write-Log "[Ceph] Dispatching new Ceph cluster creation to '$newClusterScript' (node=$clusterHostNodeIp, distribution=$clusterDistribution)" -Console
  & $newClusterScript -NodeIp $clusterHostNodeIp -Config $Config -ShowLogs:$ShowLogs
  if ($LASTEXITCODE -ne 0) {
    Write-Log "[Ceph] ERROR: New Ceph cluster creation failed (exit code $LASTEXITCODE)." -Console -Error
    if ($EncodeStructuredOutput -eq $true) {
      Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message 'New Ceph cluster creation failed') }
    }
    exit 1
  }
  Write-Log '[Ceph] New Ceph cluster created successfully; continuing with CSI installation' -Console

  # The new-cluster script wrote the ACTUAL connection values read back from the freshly
  # provisioned cluster (monitorEndpoints, cephKey, cephfsFilesystem, cephfsPool, clusterId,
  # cephUser) into $Config. Validate and load them so the placeholder values used before
  # provisioning are replaced by the real ones for the CSI installation, the ceph-config.json
  # persistence, and the usage summary printed at the end.
  Read-ValidateStorageConfig -Config $Config
}

# Apply Ceph CSI operator manifests (CRDs first, then RBAC/operator resources)
$cephManifestsDir = "$PSScriptRoot\manifests"
$cephCrdsManifest = "$cephManifestsDir\crds\ceph-crd.yaml"
$cephOperatorManifest = "$cephManifestsDir\operator.yaml"

try {
  $cephOperatorNamespace = Get-CephOperatorNamespace -OperatorManifestPath $cephOperatorManifest
  Write-Log "[Ceph] Using operator namespace '$cephOperatorNamespace' from manifest" -Console
}
catch {
  Write-Log "[Ceph] ERROR: $($_.Exception.Message)" -Console -Error
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message $_.Exception.Message) }
  }
  exit 1
}

Write-Log "[Ceph] Applying Ceph CSI CRDs" -Console
& kubectl apply --server-side -f "$cephCrdsManifest" 2>&1 | Write-Log
if ($LASTEXITCODE -ne 0) {
  Write-Log "[Ceph] ERROR: Failed to apply Ceph CRDs" -Console -Error
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "Failed to apply Ceph CRDs") }
  }
  exit 1
}

Write-Log "[Ceph] Waiting for Ceph CRDs to be established" -Console
& kubectl wait --for=condition=Established crd/cephconnections.csi.ceph.io crd/clientprofiles.csi.ceph.io crd/clientprofilemappings.csi.ceph.io --timeout=120s 2>&1 | Write-Log
if ($LASTEXITCODE -ne 0) {
  Write-Log "[Ceph] ERROR: Ceph CRDs were not established in time" -Console -Error
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "Ceph CRDs were not established in time") }
  }
  exit 1
}

Clear-KubectlDiscoveryCache

# Wait for operator namespace to be fully gone if it is still terminating from a previous disable
$nsStatus = kubectl get namespace $cephOperatorNamespace --ignore-not-found -o jsonpath='{.status.phase}' 2>$null
if ($nsStatus -eq 'Terminating') {
  Write-Log "[Ceph] Namespace '$cephOperatorNamespace' is still terminating from a previous run. Waiting for it to be gone..." -Console
  $nsWaitSecs = 120
  $nsElapsed = 0
  while ($nsElapsed -lt $nsWaitSecs) {
    Start-Sleep -Seconds 3
    $nsElapsed += 3
    $nsCheck = kubectl get namespace $cephOperatorNamespace --ignore-not-found -o jsonpath='{.metadata.name}' 2>$null
    if ([string]::IsNullOrWhiteSpace($nsCheck)) {
      Write-Log "[Ceph] Namespace '$cephOperatorNamespace' is gone after ${nsElapsed}s" -Console
      break
    }
  }
  if ($nsElapsed -ge $nsWaitSecs) {
    Write-Log "[Ceph] ERROR: Namespace '$cephOperatorNamespace' did not finish terminating within ${nsWaitSecs}s. Run 'kubectl get namespace $cephOperatorNamespace' to check status." -Console -Error
    if ($EncodeStructuredOutput -eq $true) {
      Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "Namespace '$cephOperatorNamespace' is still terminating; cannot re-enable until it is fully gone") }
    }
    exit 1
  }
}

# Create a runtime kustomization workspace and inject values from addon config
$kustomizationWorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("k2s-ceph-kustomize-" + [guid]::NewGuid().ToString())
New-Item -Path $kustomizationWorkDir -ItemType Directory -ErrorAction Stop | Out-Null
Copy-Item -Path (Join-Path $cephManifestsDir '*') -Destination $kustomizationWorkDir -Recurse -Force

$monitorList = @()
foreach ($monitor in ($MonitorEndpoints -split ',')) {
    $trimmed = $monitor.Trim()
    if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
        $monitorList += $trimmed
    }
}

if ($monitorList.Count -eq 0) {
    Write-Log "[Ceph] ERROR: No valid monitor endpoints resolved for CephConnection manifest" -Console -Error
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "No valid monitor endpoints resolved for CephConnection manifest") }
    }
    exit 1
}

$monitorYaml = (($monitorList | ForEach-Object { "    - " + (Convert-ToYamlSingleQuoted -Value $_) }) -join "`r`n")

$cephConnectionYaml = @"
apiVersion: csi.ceph.io/v1
kind: CephConnection
metadata:
  name: ceph-connection
  namespace: $cephOperatorNamespace
spec:
  monitors:
$monitorYaml
"@
Set-Content -Path (Join-Path $kustomizationWorkDir 'ceph-connection.yaml') -Value $cephConnectionYaml -Encoding UTF8

Write-Log "[Ceph] Applying Ceph CSI RBAC and operator resources" -Console
$kubectlOutput = & kubectl apply -k "$kustomizationWorkDir" 2>&1
$kubectlOutput | ForEach-Object { Write-Log "[Ceph] kubectl: $_" }
if ($LASTEXITCODE -ne 0) {
  $errorDetail = ($kubectlOutput | Where-Object { $_ -match 'Error|error|failed|invalid' }) -join '; '
  Write-Log "[Ceph] ERROR: Failed to apply Ceph CSI RBAC/operator resources: $errorDetail" -Console -Error
  Write-Log "[Ceph] Kustomize workdir preserved for inspection: $kustomizationWorkDir" -Console
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "Failed to apply Ceph CSI RBAC/operator resources") }
  }
  exit 1
}

Remove-Item -Path $kustomizationWorkDir -Recurse -Force -ErrorAction SilentlyContinue

# Create secrets with Ceph credentials
Write-Log "[Ceph] Creating Ceph credentials secrets" -Console

$cephfsSecret = @"
apiVersion: v1
kind: Secret
metadata:
  name: ceph-secret
  namespace: $cephOperatorNamespace
type: Opaque
stringData:
  adminID: $cephUser
  adminKey: $AdminKey
  userID: $cephUser
  userKey: $AdminKey
"@

$cephfsSecret | kubectl apply -f - 2>&1 | ForEach-Object { Write-Log "[Ceph] kubectl: $_" }

if ($LASTEXITCODE -ne 0) {
    Write-Log "[Ceph] ERROR: Failed to create secrets" -Console -Error
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "Failed to create secrets") }
    }
    exit 1
}

Write-Log "[Ceph] Secrets created successfully" -Console

# Create StorageClasses
Write-Log "[Ceph] Creating StorageClasses" -Console

$cephfsSC = @"
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-cephfs
provisioner: cephfs.csi.ceph.com
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  clusterID: storage
  fsName: $cephfsFilesystem
  pool: $CephfsPool
  csi.storage.k8s.io/provisioner-secret-name: ceph-secret
  csi.storage.k8s.io/provisioner-secret-namespace: $cephOperatorNamespace
  csi.storage.k8s.io/controller-expand-secret-name: ceph-secret
  csi.storage.k8s.io/controller-expand-secret-namespace: $cephOperatorNamespace
  csi.storage.k8s.io/node-stage-secret-name: ceph-secret
  csi.storage.k8s.io/node-stage-secret-namespace: $cephOperatorNamespace
"@

$cephfsSC | kubectl apply -f - 2>&1 | ForEach-Object { Write-Log "[Ceph] kubectl: $_" }

if ($LASTEXITCODE -ne 0) {
    Write-Log "[Ceph] ERROR: Failed to create StorageClasses" -Console -Error
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "Failed to create StorageClasses") }
    }
    exit 1
}

Write-Log "[Ceph] StorageClasses created successfully" -Console

# Wait for Ceph CSI workloads to become ready before reporting success.
$allReady = $true
try {
  Write-Log "[Ceph] Waiting for Ceph operator pod readiness" -Console
  $operatorReady = Wait-ForPodCondition -Condition Ready -Label 'control-plane=ceph-csi-op-controller-manager' -Namespace $cephOperatorNamespace -TimeoutSeconds 300
  $allReady = ($allReady -and $operatorReady)

  Write-Log "[Ceph] Waiting for CephFS CSI controller deployment to be created by operator" -Console
  $cephfsCtrlDeploymentName = 'cephfs.csi.ceph.com-ctrlplugin'
  $ctrlDeployTimeoutSeconds = 180
  $ctrlDeployElapsed = 0
  $ctrlDeployExists = $false
  while ($ctrlDeployElapsed -lt $ctrlDeployTimeoutSeconds) {
    $ctrlDeployResult = & kubectl get deployment $cephfsCtrlDeploymentName -n $cephOperatorNamespace --ignore-not-found -o name 2>$null
    if (-not [string]::IsNullOrWhiteSpace($ctrlDeployResult)) {
      $ctrlDeployExists = $true
      break
    }
    Start-Sleep -Seconds 3
    $ctrlDeployElapsed += 3
  }

  if (-not $ctrlDeployExists) {
    $allReady = $false
    Write-Log "[Ceph] ERROR: CephFS CSI controller deployment '$cephfsCtrlDeploymentName' was not created by operator within ${ctrlDeployTimeoutSeconds}s" -Console -Error
    Write-Log "[Ceph] Driver state for troubleshooting:" -Console
    & kubectl get driver cephfs.csi.ceph.com -n $cephOperatorNamespace -o yaml 2>&1 | Write-Log
    Write-Log "[Ceph] Operator logs (last 120 lines):" -Console
    & kubectl logs -n $cephOperatorNamespace -l 'control-plane=ceph-csi-op-controller-manager' --tail=120 2>&1 | Write-Log
  }
  else {
    Write-Log "[Ceph] Waiting for CephFS CSI controller deployment availability" -Console
    & kubectl wait deployment/$cephfsCtrlDeploymentName -n $cephOperatorNamespace --for=condition=Available --timeout=300s 2>&1 | Write-Log
    $cephfsCtrlReady = ($LASTEXITCODE -eq 0)
    $allReady = ($allReady -and $cephfsCtrlReady)
  }

  Write-Log "[Ceph] Waiting for CephFS CSI nodeplugin pod readiness" -Console
  $cephfsNodeReady = Wait-ForPodCondition -Condition Ready -Label 'app.kubernetes.io/component=cephfs-nodeplugin,app.kubernetes.io/part-of=k2s-ceph-csi' -Namespace $cephOperatorNamespace -TimeoutSeconds 300

  $allReady = ($allReady -and $cephfsNodeReady)
}
catch {
  $allReady = $false
  Write-Log "[Ceph] ERROR: Pod readiness wait failed: $($_.Exception.Message)" -Console -Error
}

if (-not $allReady) {
  $readyErrMsg = 'Ceph CSI pods did not become Ready within the timeout. Check kubectl get pods -A and pod logs for details.'
  Write-Log "[Ceph] ERROR: $readyErrMsg" -Console -Error
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message $readyErrMsg) }
  }
  exit 1
}

Write-Log "[Ceph] Ceph CSI pods are Ready" -Console

# Mark Ceph as enabled and SMB as disabled in registry
Update-StorageImplementationRegistry -Implementation 'ceph' -Enabled $true
Update-StorageImplementationRegistry -Implementation 'smb' -Enabled $false

# Register the addon (with its implementation) in setup.json so that it is reported as enabled
# by 'k2s addons ls' and recognized by Test-IsAddonEnabled. Must run only after a successful
# enable (pod readiness was already validated above).
Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = $addonName; Implementation = 'ceph' })

# Persist the effective connection configuration back to ceph-config.json so that values supplied
# via CLI flags (monitor endpoints, credentials, pool/filesystem) are captured. This is what the
# backup/restore and upgrade hooks snapshot in order to re-enable the addon later, since ceph is
# backed by an EXTERNAL cluster and has no addon-owned data of its own.
try {
  $cephConfigPathToPersist = "$PSScriptRoot\config\ceph-config.json"
  $persistedConfig = [pscustomobject]@{
    comment          = 'Ceph CSI Configuration - Update values with your Ceph cluster details'
    monitorEndpoints = $script:MonitorEndpoints
    cephUser         = $script:cephUser
    cephKey          = $script:AdminKey
    clusterId        = $script:clusterId
    cephfsPool       = $script:CephfsPool
    cephfsFilesystem = $script:cephfsFilesystem
  }

  # When the addon provisioned a NEW Ceph cluster (clusterMode != 'existing'), the cluster now
  # EXISTS, so persist clusterMode as 'existing'. This ensures a subsequent enable connects to the
  # already-provisioned cluster instead of trying to create it again. The provisioning details
  # (host node + distribution) are persisted so that Disable.ps1 can offer to tear down the
  # on-node Ceph cluster it created.
  if ($clusterMode -ne 'existing') {
    $persistedConfig | Add-Member -NotePropertyName 'clusterMode' -NotePropertyValue 'existing' -Force
    if ($Config) {
      $persistedConfig | Add-Member -NotePropertyName 'clusterHostNode' -NotePropertyValue "$($Config.clusterHostNode)" -Force
      $persistedConfig | Add-Member -NotePropertyName 'clusterHostNodeIp' -NotePropertyValue "$($Config.clusterHostNodeIp)" -Force
      $persistedConfig | Add-Member -NotePropertyName 'clusterDistribution' -NotePropertyValue "$($Config.clusterDistribution)" -Force

      # Persist the dashboard URL plus the local-access artifacts the new-cluster script created
      # (Windows hosts entry hostname + trusted-root certificate thumbprint) so Disable.ps1 can
      # remove them again when the addon is disabled.
      foreach ($dashProp in 'dashboardUrl', 'dashboardHost', 'dashboardCertThumbprint') {
        if ($Config.PSObject.Properties.Name -contains $dashProp -and -not [string]::IsNullOrWhiteSpace("$($Config.$dashProp)")) {
          $persistedConfig | Add-Member -NotePropertyName $dashProp -NotePropertyValue "$($Config.$dashProp)" -Force
        }
      }
    }
  }

  $persistedConfig | ConvertTo-Json -Depth 20 | Set-Content -Path $cephConfigPathToPersist -Encoding UTF8 -Force
  Write-Log "[Ceph] Persisted effective configuration to '$cephConfigPathToPersist'" -Console
}
catch {
  Write-Log "[Ceph] Warning: failed to persist ceph-config.json: $($_.Exception.Message)" -Console
}

# Register backup/restore/upgrade hooks so that 'k2s system backup/restore' and cluster upgrade
# preserve the ceph connection configuration.
Copy-ScriptsToHooksDir -ScriptPaths @(Get-ChildItem -Path "$PSScriptRoot\hooks" -Filter '*.ps1' | ForEach-Object { $_.FullName })

Write-Log "[Ceph] Addon enabled successfully" -Console

$dashboardUrl = if ($Config -and ($Config.PSObject.Properties.Name -contains 'dashboardUrl')) { "$($Config.dashboardUrl)" } else { '' }
$dashboardUser = if ($Config -and ($Config.PSObject.Properties.Name -contains 'dashboardUser')) { "$($Config.dashboardUser)" } else { '' }
$dashboardPassword = if ($Config -and ($Config.PSObject.Properties.Name -contains 'dashboardPassword')) { "$($Config.dashboardPassword)" } else { '' }

Write-CephUsageForUser -MonitorEndpoints $script:MonitorEndpoints `
                       -CephfsFilesystem $script:cephfsFilesystem `
                       -CephfsPool $script:CephfsPool `
                       -ClusterId $script:clusterId `
                       -DashboardUrl $dashboardUrl `
                       -DashboardUser $dashboardUser `
                       -DashboardPassword $dashboardPassword

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{
        Error = $null
        Status = "Ceph CSI addon enabled successfully"
        AddonName = $addonName
      StorageClasses = @('ceph-cephfs')
    }
}

# Update other addons that depend on storage
Update-Addons -AddonName $addonName
