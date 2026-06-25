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
$addonName = 'storage'
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
    return @{Error = $err }
}

$setupInfo = Get-SetupInfo

if ($setupInfo.Name -ne 'k2s') {
    $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon '$AddonName' can only be enabled for 'k2s' setup type."  
    return @{Error = $err }
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

function Wait-ForPodPrefixReady {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Namespace,
    [Parameter(Mandatory = $true)]
    [string]$PodPrefix,
    [int]$TimeoutSeconds = 300
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    $podNames = (& kubectl get pods -n $Namespace -o name --ignore-not-found 2>$null)
    $matchingPods = @($podNames -split "`r?`n" | Where-Object { $_ -like "pod/$PodPrefix*" -and $_ -ne '' })
    if ($matchingPods.Count -gt 0) {
      foreach ($pod in $matchingPods) {
        & kubectl wait --for=condition=Ready $pod -n $Namespace --timeout=60s 2>&1 | Write-Log
        if ($LASTEXITCODE -ne 0) {
          return $false
        }
      }
      return $true
    }

    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)

  return $false
}

function Read-ValidateStorageConfig {
param (
		[pscustomobject]$Config
	)
$cephUser = 'client.admin'
$clusterId = 'k2s-ceph'
$cephfsFilesystem = 'cephfs'

if ($null -ne $Config) {
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

$AdminKey = $AdminKey.Trim()
if ([string]::IsNullOrWhiteSpace($AdminKey)) {
  Write-Log "[Ceph] ERROR: Admin keyring resolved to empty value after trimming" -Console -Error
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "Admin keyring resolved to empty value") }
  }
  exit 1
}

Write-Log "[Ceph] Monitor endpoints: $MonitorEndpoints" -Console
Write-Log "[Ceph] CephFS pool: $CephfsPool" -Console
Write-Log "[Ceph] Ceph user: $cephUser" -Console
Write-Log "[Ceph] Ceph cluster ID: $clusterId" -Console
Write-Log "[Ceph] CephFS filesystem: $cephfsFilesystem" -Console
}

Read-ValidateStorageConfig -Config $Config

# Create Ceph CSI namespaces
# Write-Log "[Ceph] Creating Ceph CSI namespaces" -Console
# $null = kubectl create namespace ceph-csi-cephfs --dry-run=client -o yaml | kubectl apply -f -

# if ($LASTEXITCODE -ne 0) {
#     Write-Log "[Ceph] ERROR: Failed to create namespaces" -Console -Error
#     if ($EncodeStructuredOutput -eq $true) {
#         Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "Failed to create namespaces") }
#     }
#     exit 1
# }

# Write-Log "[Ceph] Namespaces created successfully" -Console

# Apply Ceph CSI operator manifests (CRDs first, then RBAC/operator resources)
$cephManifestsDir = "$PSScriptRoot\manifests"
$cephCrdsManifest = "$cephManifestsDir\crds\ceph-crd.yaml"
$cephKustomization = "$cephManifestsDir\kustomization.yaml"

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
stringData:
  key: $AdminKey
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

# Wait for Ceph CSI workloads to become ready before reporting success.
$allReady = $true
try {
  Write-Log "[Ceph] Waiting for Ceph operator pod readiness" -Console
  $operatorReady = Wait-ForPodCondition -Condition Ready -Label 'control-plane=ceph-csi-op-controller-manager' -Namespace 'ceph-csi-operator-system' -TimeoutSeconds 300
  $allReady = ($allReady -and $operatorReady)

  Write-Log "[Ceph] Waiting for CephFS CSI controller pod readiness" -Console
  $cephfsCtrlReady = Wait-ForPodPrefixReady -Namespace 'ceph-csi-operator-system' -PodPrefix 'cephfs.csi.ceph.com-ctrlplugin-' -TimeoutSeconds 300

  Write-Log "[Ceph] Waiting for CephFS CSI nodeplugin pod readiness" -Console
  $cephfsNodeReady = Wait-ForPodPrefixReady -Namespace 'ceph-csi-operator-system' -PodPrefix 'cephfs.csi.ceph.com-nodeplugin-' -TimeoutSeconds 300

  $allReady = ($allReady -and $cephfsCtrlReady -and $cephfsNodeReady)
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
