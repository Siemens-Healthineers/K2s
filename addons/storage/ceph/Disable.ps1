# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Disables Ceph CSI storage provisioner addon

.DESCRIPTION
Removes Ceph CSI operator components and optionally removes PersistentVolumes.

.PARAMETER ShowLogs
If log output shall be streamed also to CLI output.

.PARAMETER Force
Delete all PersistentVolumes when disabling (data loss)

.PARAMETER Keep
Keep all PersistentVolumes when disabling (data preserved)
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Delete all PersistentVolumes (data loss)')]
    [switch] $Force = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Keep all PersistentVolumes (data preserved)')]
    [switch] $Keep = $false,
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

<#
.SYNOPSIS
Removes the Ceph CSI Kubernetes resources (operator, driver, CRs, StorageClass, namespaces, CRDs).

.DESCRIPTION
Deletes the kustomized manifests, strips finalizers from the Ceph CSI custom resources so their
namespaces can terminate, and removes the cluster-scoped StorageClass, CSIDriver and CRDs that are
not part of any manifest.
#>
function Remove-CephCsiKubernetesResources {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestsDir
    )

    (Invoke-Kubectl -Params 'delete', '-k', $ManifestsDir, '--ignore-not-found', '--wait=false').Output | Write-Log

    $cephCrKinds = @(
        'clientprofiles.csi.ceph.io',
        'clientprofilemappings.csi.ceph.io',
        'drivers.csi.ceph.io',
        'cephconnections.csi.ceph.io',
        'operatorconfigs.csi.ceph.io'
    )
    $finalizerPatchFile = Join-Path ([System.IO.Path]::GetTempPath()) ("k2s-ceph-finalizer-" + [guid]::NewGuid().ToString() + ".json")
    Set-Content -Path $finalizerPatchFile -Value '{"metadata":{"finalizers":null}}' -Encoding ascii -NoNewline
    try {
        foreach ($crKind in $cephCrKinds) {
            $getResult = Invoke-Kubectl -Params 'get', $crKind, '--all-namespaces', '--ignore-not-found', '-o', 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name', '--no-headers'
            if (-not $getResult.Success) {
                # CRD for this kind no longer exists (already deleted) - nothing to clean up.
                continue
            }
            $crLines = @($getResult.Output | ForEach-Object { "$_" } | Where-Object { $_ -match '\S' })
            foreach ($entry in $crLines) {
                $cols = ($entry.Trim() -split '\s+')
                $crNamespace = $cols[0]
                $crName = $cols[1]
                if ([string]::IsNullOrWhiteSpace($crName)) {
                    continue
                }
                Write-Log "[Ceph] Removing finalizers from $crKind $crNamespace/$crName"
                (Invoke-Kubectl -Params 'patch', $crKind, $crName, '-n', $crNamespace, '--type', 'merge', '--patch-file', $finalizerPatchFile).Output | Write-Log
            }
        }
    }
    finally {
        Remove-Item -Path $finalizerPatchFile -Force -ErrorAction SilentlyContinue
    }

    (Invoke-Kubectl -Params 'delete', 'storageclass', 'ceph-cephfs', '--ignore-not-found').Output | Write-Log

    # Remove the CSIDriver object that the operator creates dynamically for the CephFS driver.
    # It is cluster-scoped and not part of any manifest, so 'delete -k' does not remove it and it
    # survives namespace deletion. Because the Driver CR finalizer is stripped above, the operator
    # never gets to delete it either - so remove it explicitly to avoid leaving it orphaned.
    (Invoke-Kubectl -Params 'delete', 'csidriver', 'cephfs.csi.ceph.com', '--ignore-not-found').Output | Write-Log

    (Invoke-Kubectl -Params 'delete', 'namespace', 'ceph-csi-operator-system', '--ignore-not-found', '--wait=false').Output | Write-Log

    (Invoke-Kubectl -Params 'delete', 'namespace', 'ceph-csi-cephfs', '--ignore-not-found', '--wait=false').Output | Write-Log

    (Invoke-Kubectl -Params 'delete', '-f', (Join-Path $ManifestsDir 'crds'), '--ignore-not-found', '--wait=false').Output | Write-Log
}

<#
.SYNOPSIS
Resolves the name and IP of the node that hosts the provisioned Ceph cluster.

.DESCRIPTION
The target node is identified by 'clusterHostNode' in ceph-config.json. The K2s control plane node
(e.g. 'kubemaster') is NOT stored in cluster.json, so its IP comes from the control-plane
configuration; any other node is resolved from the K2s cluster descriptor (cluster.json). Returns an
object with 'Name' and 'Ip' (empty 'Ip' when it cannot be resolved).
#>
function Get-CephClusterHostNode {
    param(
        [pscustomobject]$Config
    )

    $clusterHostNode = if ($Config -and ($Config.PSObject.Properties.Name -contains 'clusterHostNode')) { "$($Config.clusterHostNode)".Trim() } else { '' }
    $clusterHostNodeIp = ''
    if (-not [string]::IsNullOrWhiteSpace($clusterHostNode)) {
        $controlPlaneNodeName = Get-ConfigControlPlaneNodeHostname
        if ($clusterHostNode -eq $controlPlaneNodeName) {
            $clusterHostNodeIp = "$(Get-ConfiguredIPControlPlane)".Trim()
        }
        else {
            $targetNodeConfig = Get-NodeConfig -NodeName $clusterHostNode
            if ($null -ne $targetNodeConfig) {
                $clusterHostNodeIp = "$($targetNodeConfig.IpAddress)".Trim()
            }
            else {
                Write-Log "[Ceph] WARNING: Node '$clusterHostNode' from ceph-config.json was not found in cluster.json; cannot resolve its IP for on-node Ceph cluster teardown." -Console
            }
        }
    }

    return [pscustomobject]@{ Name = $clusterHostNode; Ip = $clusterHostNodeIp }
}

<#
.SYNOPSIS
Clears the recorded Ceph cluster FSID ('cephClusterId') from ceph-config.json.

.DESCRIPTION
Called after the on-node cluster is torn down so a subsequent enable/disable does not reference a
stale cluster id.
#>
function Clear-CephRecordedClusterId {
    param(
        [Parameter(Mandatory = $true)][string]$CephConfigFilePath
    )

    try {
        if (Test-Path $CephConfigFilePath) {
            $cephConfigOnDisk = Get-Content -Path $CephConfigFilePath -Raw | ConvertFrom-Json
            if ($cephConfigOnDisk.PSObject.Properties.Name -contains 'cephClusterId') {
                $cephConfigOnDisk.cephClusterId = ''
                $cephConfigOnDisk | ConvertTo-Json -Depth 10 | Set-Content -Path $CephConfigFilePath -Encoding UTF8
                Write-Log "[Ceph] Cleared recorded Ceph cluster id in $CephConfigFilePath" -Console
            }
        }
    }
    catch {
        Write-Log "[Ceph] WARNING: Could not clear Ceph cluster id in '$CephConfigFilePath': $($_.Exception.Message)" -Console
    }
}

<#
.SYNOPSIS
Tears down the Ceph cluster that the addon provisioned on the host node.

.DESCRIPTION
The addon ALWAYS provisions a new Ceph cluster on enable, so disabling must tear it down. Deleting
that cluster is destructive and irreversible, so an explicit, dedicated confirmation is required
(separate from the PVC data prompt). Explicit -Force deletes and -Keep preserves without prompting;
otherwise the user is asked interactively. Only Debian 13 nodes are supported.
#>
function Remove-ProvisionedCephClusterOnNode {
    param(
        [Parameter(Mandatory = $true)][string]$ClusterHostNode,
        [Parameter(Mandatory = $true)][string]$ClusterHostNodeIp,
        [pscustomobject]$Config,
        [bool]$ForceProvided,
        [bool]$KeepProvided,
        [Parameter(Mandatory = $true)][string]$RemoveClusterScript,
        [Parameter(Mandatory = $true)][string]$CephConfigFilePath,
        [switch]$ShowLogs
    )

    # Use the flags as ORIGINALLY passed on the command line, NOT the values set by the interactive
    # PVC data prompt (which is a separate decision). When neither is set, always ask for a dedicated
    # confirmation - Read-Host still works against the console even in -EncodeStructuredOutput mode.
    $deleteCephCluster = $false
    if ($ForceProvided) {
        $deleteCephCluster = $true
    }
    elseif ($KeepProvided) {
        $deleteCephCluster = $false
    }
    else {
        Write-Log '' -Console
        Write-Log "[Ceph] WARNING: The storage ceph addon provisioned a Ceph cluster on host node '$ClusterHostNode' ($ClusterHostNodeIp)." -Console
        $answer = Read-Host "Do you want to DELETE the Ceph cluster on host node '$ClusterHostNode'? This destroys the cluster and ALL its data and cannot be undone. (y/N)"
        if ($answer -eq 'y') {
            $deleteCephCluster = $true
            Write-Log "[Ceph] CEPH CLUSTER DELETION CONFIRMED for host node '$ClusterHostNodeIp'." -Console
        }
        else {
            Write-Log "[Ceph] Ceph cluster on host node '$ClusterHostNodeIp' will be KEPT." -Console
        }
    }

    if (-not $deleteCephCluster) {
        Write-Log "[Ceph] Only the addon/CSI resources were removed. The Ceph cluster on host node '$ClusterHostNodeIp' was NOT deleted." -Console
        return
    }

    if (-not (Test-Path $RemoveClusterScript)) {
        Write-Log "[Ceph] WARNING: Teardown script not found at '$RemoveClusterScript'; skipping on-node Ceph cluster teardown." -Console
        return
    }

    # Only Debian 13 nodes are supported, so the Debian teardown script is always used.
    Write-Log "[Ceph] Tearing down provisioned Ceph cluster on node '$ClusterHostNode' ($ClusterHostNodeIp)" -Console
    & $RemoveClusterScript -NodeIp $ClusterHostNodeIp -Config $Config -ShowLogs:$ShowLogs
    if ($LASTEXITCODE -ne 0) {
        Write-Log "[Ceph] WARNING: On-node Ceph cluster teardown reported a non-zero exit code ($LASTEXITCODE). Manual cleanup on '$ClusterHostNodeIp' may be required." -Console
        return
    }

    Write-Log '[Ceph] On-node Ceph cluster teardown completed' -Console
    Clear-CephRecordedClusterId -CephConfigFilePath $CephConfigFilePath
}

<#
.SYNOPSIS
Removes the Windows hosts-file entry that Enable.ps1 may have created for the Ceph dashboard.

.DESCRIPTION
Older enables mapped the dashboard hostname to the node IP in the Windows hosts file. This cleans up
that entry (identified by 'dashboardHost' in the config) when present.
#>
function Remove-CephDashboardHostEntry {
    param(
        [pscustomobject]$Config
    )

    $clusterHostNode = if ($Config -and ($Config.PSObject.Properties.Name -contains 'clusterHostNode')) { "$($Config.clusterHostNode)".Trim() } else { '' }
    $controlPlaneNodeName = Get-ConfigControlPlaneNodeHostname
    if (-not [string]::IsNullOrWhiteSpace($clusterHostNode) -and $clusterHostNode -eq $controlPlaneNodeName) {
        Write-Log "[Ceph] Skipping dashboard hosts-entry cleanup for control plane node '$clusterHostNode'." -Console
        return
    }

    $dashboardHost = if ($Config -and ($Config.PSObject.Properties.Name -contains 'dashboardHost')) { "$($Config.dashboardHost)".Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($dashboardHost)) {
        return
    }

    $hostFile = 'C:\Windows\System32\drivers\etc\hosts'
    try {
        if (Test-Path $hostFile) {
            $pattern = '^\s*\S+\s+' + [regex]::Escape($dashboardHost) + '\s*$'
            $content = @(Get-Content -Path $hostFile)
            $filtered = @($content | Where-Object { $_ -notmatch $pattern })
            if ($filtered.Count -ne $content.Count) {
                # Use WriteAllLines instead of Set-Content: Set-Content throws
                # 'Stream was not readable' when the resulting array is empty (e.g. the
                # dashboard entry was the only line in the hosts file).
                [System.IO.File]::WriteAllLines($hostFile, [string[]]$filtered, [System.Text.Encoding]::ASCII)
                Write-Log "[Ceph] Removed hosts entry for '$dashboardHost' from '$hostFile'" -Console
            }
        }
    }
    catch {
        Write-Log "[Ceph] WARNING: Failed to remove hosts entry for '$dashboardHost': $($_.Exception.Message)" -Console
    }
}

<#
.SYNOPSIS
Removes the Ceph CSI container images that were pulled onto the K2s cluster node(s).

.DESCRIPTION
The k8s resource deletions only remove the pods; their cached images stay in containerd until
explicitly removed. The exact image references are read from the storage addon manifest's ceph
'additionalImages' list so this stays in sync with what the addon installs. Only that exact repo:tag
list is removed (not a broad namespace) so images other addons might share are untouched. These
images are re-imported from the offline package on the next enable.
#>
function Remove-CephCsiNodeImages {
    param(
        [Parameter(Mandatory = $true)][string]$StorageManifestPath
    )

    try {
        if (-not (Test-Path $StorageManifestPath)) {
            Write-Log "[Ceph] WARNING: Storage addon manifest not found at '$StorageManifestPath'; skipping node image cleanup." -Console
            return
        }

        # Collect the ceph CSI image references (repo:tag) declared under additionalImages. The
        # smb implementation declares an empty additionalImages list, so only the ceph entries
        # (quay.io/ceph, quay.io/cephcsi, registry.k8s.io/sig-storage) match here.
        $cephImageRefs = @(
            Get-Content -Path $StorageManifestPath |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -match '^-\s+(quay\.io/ceph/|quay\.io/cephcsi/|registry\.k8s\.io/sig-storage/)\S+:\S+$' } |
            ForEach-Object { ($_ -replace '^-\s+', '').Trim() } |
            Select-Object -Unique
        )

        if ($cephImageRefs.Count -eq 0) {
            Write-Log '[Ceph] No Ceph CSI images found in storage addon manifest; skipping node image cleanup.'
            return
        }

        Write-Log "[Ceph] Removing $($cephImageRefs.Count) Ceph CSI image(s) from the K2s cluster node(s)" -Console

        # Enumerate the images actually present on the nodes so we can map each manifest reference to
        # its ContainerImage (with ImageId/Node) for Remove-Image.
        $nodeImages = @(Get-ContainerImagesInk2s -IncludeK8sImages $true)

        foreach ($imageRef in $cephImageRefs) {
            $matchingImages = @($nodeImages | Where-Object { "$($_.Repository):$($_.Tag)" -eq $imageRef })
            if ($matchingImages.Count -eq 0) {
                Write-Log "[Ceph] Image '$imageRef' not present on any node; nothing to remove."
                continue
            }

            foreach ($img in $matchingImages) {
                try {
                    $removeResult = Remove-Image -ContainerImage $img -Force
                    if ("$removeResult" -match '__K2S_IMAGE_DELETE_FAILED__') {
                        Write-Log "[Ceph] WARNING: Failed to remove image '$imageRef' from node '$($img.Node)': $removeResult" -Console
                    }
                    else {
                        Write-Log "[Ceph] Removed image '$imageRef' from node '$($img.Node)'" -Console
                    }
                }
                catch {
                    Write-Log "[Ceph] WARNING: Failed to remove image '$imageRef' from node '$($img.Node)': $($_.Exception.Message)" -Console
                }
            }
        }
    }
    catch {
        Write-Log "[Ceph] WARNING: Ceph CSI image cleanup on the cluster node(s) failed: $($_.Exception.Message)" -Console
    }
}

$forceFlagProvided = $PSBoundParameters.ContainsKey('Force') -and $Force
$keepFlagProvided = $PSBoundParameters.ContainsKey('Keep') -and $Keep

Write-Log 'Checking cluster status' -Console
$addonName = Get-AddonNameFromFolderPath -BaseFolderPath $PSScriptRoot

if ($null -eq $Config) {
    $cephConfigPath = "$PSScriptRoot\config\ceph-config.json"
    if (Test-Path $cephConfigPath) {
        try {
            $Config = Get-Content -Path $cephConfigPath -Raw | ConvertFrom-Json
        }
        catch {
            Write-Log "[Ceph] Warning: failed to parse ceph-config.json for teardown detection: $($_.Exception.Message)" -Console
        }
    }
}

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }
    Write-Log $systemError.Message -Error
    exit 1
}

Write-Log 'Check whether storage ceph addon is already disabled'
if ($null -eq (Invoke-Kubectl -Params 'get', 'namespace', 'ceph-csi-operator-system', '--ignore-not-found').Output -and (Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'storage'; Implementation = 'ceph' })) -ne $true) {
    $errMsg = "Addon 'storage ceph' is already disabled, nothing to do."
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyDisabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

if ($Force -and $Keep) {
    $errMsg = 'Disable storage ceph failed: Cannot use both Force and Keep parameters at the same time.'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Error -Code (Get-ErrCodeInvalidParameter) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

if (-not $Force -and -not $Keep) {
    $answer = Read-Host 'Do you want to DELETE ALL DATA on the Ceph (CephFS) volumes? Otherwise, all data will be kept. (y/N)'
    if ($answer -eq 'y') {
        $Force = $true
        Write-Log 'DATA DELETION CONFIRMED. All PersistentVolumes on the Ceph storage will be deleted.' -Console
    }
    else {
        $Keep = $true
        Write-Log 'DATA WILL BE KEPT. No PersistentVolumes on the Ceph storage will be deleted.' -Console
    }
}

Write-Log 'Uninstalling storage ceph' -Console

if (-not $Keep) {
    Write-Log '[Ceph] Deleting PersistentVolumeClaims bound to StorageClass ceph-cephfs' -Console
    Remove-PersistentVolumeClaimsForStorageClass -StorageClass 'ceph-cephfs' | Write-Log
}

Remove-CephCsiKubernetesResources -ManifestsDir "$PSScriptRoot\manifests"

$cephHostNode = Get-CephClusterHostNode -Config $Config
if (-not [string]::IsNullOrWhiteSpace($cephHostNode.Ip)) {
    Remove-ProvisionedCephClusterOnNode -ClusterHostNode $cephHostNode.Name `
        -ClusterHostNodeIp $cephHostNode.Ip `
        -Config $Config `
        -ForceProvided $forceFlagProvided `
        -KeepProvided $keepFlagProvided `
        -RemoveClusterScript "$PSScriptRoot\scripts\linux\debian\Remove-CephCluster.ps1" `
        -CephConfigFilePath "$PSScriptRoot\config\ceph-config.json" `
        -ShowLogs:$ShowLogs
}

# Remove the local dashboard-access artifact that an older Enable.ps1 may have created (Windows
# hosts entry hostname -> node IP).
Remove-CephDashboardHostEntry -Config $Config

# Remove the Ceph CSI container images that were pulled onto the K2s cluster node(s).
Remove-CephCsiNodeImages -StorageManifestPath (Join-Path -Path $PSScriptRoot -ChildPath '..\addon.manifest.yaml')

# Mark Ceph as disabled in registry
Update-StorageImplementationRegistry -Implementation 'ceph' -Enabled $false

# Remove the addon (with its implementation) from setup.json so that 'k2s addons ls' no longer
# reports it as enabled and Test-IsAddonEnabled returns false.
Remove-AddonFromSetupJson -Addon ([pscustomobject] @{Name = $addonName; Implementation = 'ceph' })

# Unregister the backup/restore/upgrade hooks.
Remove-ScriptsFromHooksDir -ScriptNames @(Get-ChildItem -Path "$PSScriptRoot\hooks" -Filter '*.ps1' | ForEach-Object { $_.Name })

Write-Log "[Ceph] Addon disabled successfully" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{
        Error = $null
        Status = "Storage ceph addon disabled successfully"
        AddonName = $addonName
        DataAction = if ($Force) { "deleted" } elseif ($Keep) { "preserved" } else { "prompted" }
    }
}
