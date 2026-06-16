# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
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

$infraModule = "$PSScriptRoot/../../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"
$validationModule = "$PSScriptRoot\..\storage-validation.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule, $validationModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log "[Ceph] Enabling Ceph CSI storage addon" -Console

# If no config object is provided by the caller, fall back to the local Ceph config file.
if ($Config -eq $null) {
  $cephConfigPath = "$PSScriptRoot\config\ceph-config.json"
  if (Test-Path -LiteralPath $cephConfigPath) {
    try {
      $Config = Get-Content -LiteralPath $cephConfigPath -Raw | ConvertFrom-Json
      Write-Log "[Ceph] Loaded configuration from '$cephConfigPath'" -Console
    }
    catch {
      Write-Log "[Ceph] WARNING: Failed to parse config file '$cephConfigPath'. Falling back to CLI flags only. Error: $($_.Exception.Message)" -Console
    }
  }
}

# Validate no conflicting storage implementation is enabled
$conflictError = Test-ConflictingStorageImplementation -RequestedImplementation 'ceph'
if ($conflictError) {
    Write-Log "[Ceph] ERROR: $conflictError" -Console -Error
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = (New-Error -Code 'storage-conflict' -Message $conflictError) }
    }
    exit 1
}

# Get addon name
$addonName = Get-AddonNameFromFolderPath -BaseFolderPath $PSScriptRoot

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

# (no polling helpers needed — kubectl wait is used directly below)

# Resolve config values (config file values override CLI parameters)
$cephUser = 'client.admin'
$clusterId = 'k2s-ceph'
$cephfsFilesystem = 'cephfs'

if ($Config -ne $null) {
  if (-not [string]::IsNullOrWhiteSpace($Config.monitorEndpoints)) {
    Write-Log "[Ceph] Using monitor endpoints from addon config" -Console
    $MonitorEndpoints = $Config.monitorEndpoints
  }

  if (-not [string]::IsNullOrWhiteSpace($Config.cephKey)) {
    Write-Log "[Ceph] Using ceph key from addon config" -Console
    $AdminKey = $Config.cephKey
  }

  if (-not [string]::IsNullOrWhiteSpace($Config.cephfsPool)) {
    Write-Log "[Ceph] Using CephFS pool '$($Config.cephfsPool)' from addon config" -Console
    $CephfsPool = $Config.cephfsPool
  }

  if (-not [string]::IsNullOrWhiteSpace($Config.cephUser)) {
    $cephUser = $Config.cephUser
  }

  if (-not [string]::IsNullOrWhiteSpace($Config.clusterId)) {
    $clusterId = $Config.clusterId
  }

  if (-not [string]::IsNullOrWhiteSpace($Config.cephfsFilesystem)) {
    $cephfsFilesystem = $Config.cephfsFilesystem
  }

}

Write-Log "[Ceph] Validating Ceph configuration" -Console

# Validate inputs
if (-not $MonitorEndpoints) {
    Write-Log "[Ceph] ERROR: Monitor endpoints are required. Provide via --monitorEndpoints flag or config file" -Console -Error
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "Monitor endpoints required") }
    }
    exit 1
}

if (-not $AdminKey) {
    Write-Log "[Ceph] ERROR: Admin keyring is required. Provide via --adminKey flag or config file" -Console -Error
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "Admin keyring required") }
    }
    exit 1
}

Write-Log "[Ceph] Monitor endpoints: $MonitorEndpoints" -Console
Write-Log "[Ceph] CephFS pool: $CephfsPool" -Console
Write-Log "[Ceph] Ceph user: $cephUser" -Console
Write-Log "[Ceph] Ceph cluster ID: $clusterId" -Console
Write-Log "[Ceph] CephFS filesystem: $cephfsFilesystem" -Console

# Check cluster availability
Write-Log "[Ceph] Checking cluster status" -Console
$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    Write-Log "[Ceph] ERROR: Cluster not available: $systemError" -Console -Error
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
    }
    exit 1
}

# Safety net: if a prior disable is still in progress, wait for its resources to be gone.
Write-Log "[Ceph] Checking for terminating Ceph resources from previous disable" -Console
$waitTargets = @(
    'namespace/ceph-csi-operator-system',
    'namespace/ceph-csi-cephfs',
    'crd/cephconnections.csi.ceph.io',
    'crd/clientprofiles.csi.ceph.io',
    'crd/clientprofilemappings.csi.ceph.io'
)
foreach ($target in $waitTargets) {
    $kind, $name = $target -split '/', 2
    $exists = (& kubectl get $kind $name --ignore-not-found -o name 2>$null)
    if ([string]::IsNullOrWhiteSpace($exists)) { continue }

    Write-Log "[Ceph] Waiting for $target to be deleted" -Console
    & kubectl wait --for=delete $target --timeout=120s 2>$null
    $still = (& kubectl get $kind $name --ignore-not-found -o name 2>$null)
    if (-not [string]::IsNullOrWhiteSpace($still)) {
        $waitErrMsg = "$target is still present after waiting 120s. Please check for stuck finalizers and retry."
        Write-Log "[Ceph] ERROR: $waitErrMsg" -Console -Error
        if ($EncodeStructuredOutput -eq $true) {
            Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message $waitErrMsg) }
        }
        exit 1
    }
}

# Create Ceph CSI namespaces
Write-Log "[Ceph] Creating Ceph CSI namespaces" -Console
$null = kubectl create namespace ceph-csi-cephfs --dry-run=client -o yaml | kubectl apply -f -

if ($LASTEXITCODE -ne 0) {
    Write-Log "[Ceph] ERROR: Failed to create namespaces" -Console -Error
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "Failed to create namespaces") }
    }
    exit 1
}

Write-Log "[Ceph] Namespaces created successfully" -Console

# Apply Ceph CSI operator manifests (CRDs first, then RBAC/operator resources)
$cephManifestsDir = "$PSScriptRoot\manifests"
$cephCrdsManifest = "$cephManifestsDir\crds\crd.yaml"
$cephKustomization = "$cephManifestsDir\kustomization.yaml"

if (-not (Test-Path -Path $cephCrdsManifest)) {
  Write-Log "[Ceph] ERROR: CRD manifest not found at $cephCrdsManifest" -Console -Error
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "Ceph CRD manifest not found") }
  }
  exit 1
}

if (-not (Test-Path -Path $cephKustomization)) {
  Write-Log "[Ceph] ERROR: Kustomization manifest not found at $cephKustomization" -Console -Error
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "Ceph kustomization manifest not found") }
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

# Create a runtime kustomization workspace and inject values from addon config
$kustomizationWorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("k2s-ceph-kustomize-" + [guid]::NewGuid().ToString())
New-Item -Path $kustomizationWorkDir -ItemType Directory -ErrorAction Stop | Out-Null
Copy-Item -Path (Join-Path $cephManifestsDir '*') -Destination $kustomizationWorkDir -Recurse -Force

$cephClientId = $cephUser -replace '^client\.', ''
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
  namespace: ceph-csi-operator-system
spec:
  monitors:
$monitorYaml
"@
Set-Content -Path (Join-Path $kustomizationWorkDir 'ceph-connection.yaml') -Value $cephConnectionYaml -Encoding UTF8

Write-Log "[Ceph] Applying Ceph CSI RBAC and operator resources" -Console
& kubectl apply -k "$kustomizationWorkDir" 2>&1 | Write-Log
if ($LASTEXITCODE -ne 0) {
  Write-Log "[Ceph] ERROR: Failed to apply Ceph CSI RBAC/operator resources" -Console -Error
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "Failed to apply Ceph CSI RBAC/operator resources") }
  }
  Remove-Item -Path $kustomizationWorkDir -Recurse -Force -ErrorAction SilentlyContinue
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
  namespace: ceph-csi-cephfs
type: Opaque
data:
  key: $AdminKey
stringData:
  admin_id: $cephUser
  monitors: "$MonitorEndpoints"
"@

$cephfsSecret | kubectl apply -f -

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
  monitors: "$MonitorEndpoints"
  fsName: $cephfsFilesystem
  pool: $CephfsPool
  cephUser: $cephUser
  csi.storage.k8s.io/provisioner-secret-name: ceph-secret
  csi.storage.k8s.io/provisioner-secret-namespace: ceph-csi-cephfs
  csi.storage.k8s.io/node-stage-secret-name: ceph-secret
  csi.storage.k8s.io/node-stage-secret-namespace: ceph-csi-cephfs
  csi.storage.k8s.io/node-publish-secret-name: ceph-secret
  csi.storage.k8s.io/node-publish-secret-namespace: ceph-csi-cephfs
"@

$cephfsSC | kubectl apply -f -

if ($LASTEXITCODE -ne 0) {
    Write-Log "[Ceph] ERROR: Failed to create StorageClasses" -Console -Error
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "Failed to create StorageClasses") }
    }
    exit 1
}

Write-Log "[Ceph] StorageClasses created successfully" -Console

# Mark Ceph as enabled and SMB as disabled in registry
Update-StorageImplementationRegistry -Implementation 'ceph' -Enabled $true
Update-StorageImplementationRegistry -Implementation 'smb' -Enabled $false

Write-Log "[Ceph] Addon enabled successfully" -Console

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
