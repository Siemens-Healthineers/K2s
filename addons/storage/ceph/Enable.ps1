# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Enables Ceph CSI storage provisioner addon

.DESCRIPTION
Always provisions a NEW Ceph cluster on a K2s Debian 13 node and deploys the Ceph CSI operator
components for CephFS (file) provisioning without the Rook operator. The Ceph host node is
identified by 'clusterHostNode' in ceph-config.json; its IP address and SSH user are resolved from
the K2s cluster descriptor (cluster.json). When 'clusterHostNode' matches the K2s control plane
node name, Ceph is installed on the kubemaster; otherwise on the named node. Only Debian 13 nodes
are supported.

.PARAMETER ShowLogs
If log output shall be streamed also to CLI output.

.PARAMETER CephfsPool
CephFS data pool name (default: cephfs_data)
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
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
$nodeModule = "$PSScriptRoot/../../../lib/modules/k2s/k2s.node.module/k2s.node.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"
$validationModule = "$PSScriptRoot\..\storage-validation.module.psm1"
Import-Module $infraModule, $clusterModule, $nodeModule, $addonsModule, $validationModule

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

function Read-CephConnectionConfig {
  param (
    [pscustomobject]$Config
  )
  # The new-cluster script writes the connection values read back from the freshly provisioned
  # cluster (monitorEndpoints, cephKey, cephfsFilesystem, cephfsPool, clusterId, cephUser) into
  # $Config. Load them into script scope so the CSI secret, CephConnection and StorageClass point
  # at the real cluster. Defaults only cover the rare case where a value is absent.
  $script:cephUser = if ($Config -and -not [string]::IsNullOrWhiteSpace($Config.cephUser)) { "$($Config.cephUser)" } else { 'client.admin' }
  $script:clusterId = if ($Config -and -not [string]::IsNullOrWhiteSpace($Config.clusterId)) { "$($Config.clusterId)" } else { 'k2s-ceph' }
  $script:cephfsFilesystem = if ($Config -and -not [string]::IsNullOrWhiteSpace($Config.cephfsFilesystem)) { "$($Config.cephfsFilesystem)" } else { 'cephfs' }

  if ($Config -and -not [string]::IsNullOrWhiteSpace($Config.cephfsPool)) { $script:CephfsPool = "$($Config.cephfsPool)" }
  if ($Config -and -not [string]::IsNullOrWhiteSpace($Config.monitorEndpoints)) { $script:MonitorEndpoints = "$($Config.monitorEndpoints)" }
  if ($Config -and -not [string]::IsNullOrWhiteSpace($Config.cephKey)) { $script:AdminKey = "$($Config.cephKey)".Trim() }
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


$clusterHostNode = if ($Config -and ($Config.PSObject.Properties.Name -contains 'clusterHostNode')) { "$($Config.clusterHostNode)".Trim() } else { '' }

if ([string]::IsNullOrWhiteSpace($clusterHostNode)) {
  Write-Log "[Ceph] ERROR: 'clusterHostNode' is required in ceph-config.json." -Console -Error
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "'clusterHostNode' is required in ceph-config.json") }
  }
  exit 1
}

$controlPlaneNodeName = Get-ConfigControlPlaneNodeHostname
if ($clusterHostNode -eq $controlPlaneNodeName) {
  $clusterHostNodeIp = "$(Get-ConfiguredIPControlPlane)".Trim()
  $clusterHostNodeUser = "$(Get-DefaultUserNameControlPlane)".Trim()
  Write-Log "[Ceph] 'clusterHostNode' ('$clusterHostNode') is the K2s control plane node; the Ceph cluster will be installed on the kubemaster (IP $clusterHostNodeIp)." -Console
}
else {
  $targetNodeConfig = Get-NodeConfig -NodeName $clusterHostNode
  if ($null -eq $targetNodeConfig) {
    Write-Log "[Ceph] ERROR: Node '$clusterHostNode' was not found in cluster.json. 'clusterHostNode' must be the K2s control plane node name (e.g. '$controlPlaneNodeName') or the name of a worker node that is part of the K2s cluster." -Console -Error
    if ($EncodeStructuredOutput -eq $true) {
      Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "Node '$clusterHostNode' not found in cluster.json") }
    }
    exit 1
  }
  $clusterHostNodeIp = "$($targetNodeConfig.IpAddress)".Trim()
  $clusterHostNodeUser = "$($targetNodeConfig.Username)".Trim()
  Write-Log "[Ceph] The Ceph cluster will be installed on node '$clusterHostNode' (IP $clusterHostNodeIp)." -Console
}

if ([string]::IsNullOrWhiteSpace($clusterHostNodeIp)) {
  Write-Log "[Ceph] ERROR: Could not resolve an IP address for node '$clusterHostNode'." -Console -Error
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "Could not resolve an IP address for node '$clusterHostNode'") }
  }
  exit 1
}
if ([string]::IsNullOrWhiteSpace($clusterHostNodeUser)) { $clusterHostNodeUser = 'remote' }

# The Ceph host node MUST run Debian 13. Detect the live distribution over SSH and reject anything else.
Write-Log "[Ceph] Validating that node '$clusterHostNode' ($clusterHostNodeIp) runs Debian 13" -Console
$installedDistribution = ''
try {
  $installedDistribution = (Get-InstalledDistribution -UserName $clusterHostNodeUser -IpAddress $clusterHostNodeIp).Trim().ToLowerInvariant()
}
catch {
  Write-Log "[Ceph] ERROR: Could not determine the OS distribution of node '$clusterHostNode' ($clusterHostNodeIp) over SSH: $($_.Exception.Message)" -Console -Error
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "Could not determine the OS distribution of node '$clusterHostNode'") }
  }
  exit 1
}

if ($installedDistribution -ne 'debian13') {
  Write-Log "[Ceph] ERROR: The Ceph host node '$clusterHostNode' must run Debian 13, but detected '$installedDistribution'. Only Debian 13 nodes are supported." -Console -Error
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "Ceph host node '$clusterHostNode' must run Debian 13 (detected '$installedDistribution')") }
  }
  exit 1
}
Write-Log "[Ceph] Node '$clusterHostNode' runs Debian 13" -Console

# Always provision a fresh Ceph cluster on the target Debian 13 node before installing CSI.
$newClusterScript = "$PSScriptRoot\scripts\linux\debian\New-CephCluster.ps1"
if (-not (Test-Path $newClusterScript)) {
  Write-Log "[Ceph] ERROR: New Ceph cluster creation script not found at '$newClusterScript'." -Console -Error
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message 'New Ceph cluster creation script not found') }
  }
  exit 1
}

Write-Log "[Ceph] Dispatching new Ceph cluster creation to '$newClusterScript' (node=$clusterHostNode, ip=$clusterHostNodeIp)" -Console
& $newClusterScript -NodeIp $clusterHostNodeIp -Config $Config -ShowLogs:$ShowLogs
if ($LASTEXITCODE -ne 0) {
  Write-Log "[Ceph] ERROR: New Ceph cluster creation failed (exit code $LASTEXITCODE)." -Console -Error
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message 'New Ceph cluster creation failed') }
  }
  exit 1
}
Write-Log '[Ceph] New Ceph cluster created successfully; continuing with CSI installation' -Console

# The new-cluster script wrote the ACTUAL connection values read back from the freshly provisioned
# cluster (monitorEndpoints, cephKey, cephfsFilesystem, cephfsPool, clusterId, cephUser) into
# $Config. Load them so the CSI installation connects to the real cluster.
Read-CephConnectionConfig -Config $Config

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

Update-StorageImplementationRegistry -Implementation 'ceph' -Enabled $true
Update-StorageImplementationRegistry -Implementation 'smb' -Enabled $false

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = $addonName; Implementation = 'ceph' })

Copy-ScriptsToHooksDir -ScriptPaths @(Get-ChildItem -Path "$PSScriptRoot\hooks" -Filter '*.ps1' | ForEach-Object { $_.FullName })

Write-Log "[Ceph] Addon enabled successfully" -Console

$cephClusterFsid = "$($script:clusterId)".Trim()
if (-not [string]::IsNullOrWhiteSpace($cephClusterFsid)) {
  $cephConfigFilePath = "$PSScriptRoot\config\ceph-config.json"
  try {
    if (Test-Path $cephConfigFilePath) {
      $cephConfigOnDisk = Get-Content -Path $cephConfigFilePath -Raw | ConvertFrom-Json
    }
    else {
      $cephConfigOnDisk = [pscustomobject]@{}
    }
    if ($cephConfigOnDisk.PSObject.Properties.Name -contains 'cephClusterId') {
      $cephConfigOnDisk.cephClusterId = $cephClusterFsid
    }
    else {
      $cephConfigOnDisk | Add-Member -MemberType NoteProperty -Name 'cephClusterId' -Value $cephClusterFsid
    }
    $cephConfigOnDisk | ConvertTo-Json -Depth 10 | Set-Content -Path $cephConfigFilePath -Encoding UTF8
    Write-Log "[Ceph] Recorded Ceph cluster id '$cephClusterFsid' in $cephConfigFilePath" -Console
  }
  catch {
    Write-Log "[Ceph] WARNING: Could not persist Ceph cluster id to '$cephConfigFilePath': $($_.Exception.Message)" -Console
  }
}

$dashboardUrl = if ($Config -and ($Config.PSObject.Properties.Name -contains 'dashboardUrl')) { "$($Config.dashboardUrl)" } else { '' }
$dashboardUser = if ($Config -and ($Config.PSObject.Properties.Name -contains 'dashboardUser')) { "$($Config.dashboardUser)" } else { '' }
$dashboardPassword = if ($Config -and ($Config.PSObject.Properties.Name -contains 'dashboardPassword')) { "$($Config.dashboardPassword)" } else { '' }

Write-CephUsageForUser -CephfsFilesystem $script:cephfsFilesystem `
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
