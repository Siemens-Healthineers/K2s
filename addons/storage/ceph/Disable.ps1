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

# Capture which data-handling flags were EXPLICITLY passed on the command line before the
# interactive PVC data prompt below mutates $Force/$Keep. The on-node Ceph cluster deletion is a
# separate decision from the PVC data handling, so it must not be inferred from the PVC prompt's
# answer - only from an explicit -Force/-Keep on the invocation.
$forceFlagProvided = $PSBoundParameters.ContainsKey('Force') -and $Force
$keepFlagProvided = $PSBoundParameters.ContainsKey('Keep') -and $Keep

Write-Log 'Checking cluster status' -Console
# get addon name from folder path
$addonName = Get-AddonNameFromFolderPath -BaseFolderPath $PSScriptRoot

# When the CLI does not pass a -Config object, fall back to the addon config file so we know
# whether the addon had provisioned a NEW Ceph cluster on a node that must be torn down as well.
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

# When neither -Force nor -Keep is given, ask the user (same behavior as the SMB storage addon)
# whether the data on the Ceph (CephFS) volumes should be deleted or preserved.
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

# When not keeping data, delete the PVCs bound to the ceph-cephfs StorageClass while the CSI
# driver is still running, so the StorageClass reclaimPolicy=Delete frees the underlying CephFS
# subvolumes. Doing this after the driver/operator is removed below would leave the subvolumes
# orphaned on the external Ceph cluster.
if (-not $Keep) {
    Write-Log '[Ceph] Deleting PersistentVolumeClaims bound to StorageClass ceph-cephfs' -Console
    Remove-PersistentVolumeClaimsForStorageClass -StorageClass 'ceph-cephfs' | Write-Log
}

$cephStorageYamlDir = "$PSScriptRoot\manifests"
(Invoke-Kubectl -Params 'delete', '-k', $cephStorageYamlDir, '--ignore-not-found', '--wait=false').Output | Write-Log

# Remove finalizers from any remaining Ceph CSI custom resources. The operator normally
# clears these finalizers, but since its namespace is deleted below, nobody would remove
# them afterwards - leaving the CRs (and thus their CRDs) stuck in 'Terminating' forever.
# The finalizer patch is written to a temp file and passed via --patch-file, and the CR
# list is retrieved with custom-columns; both avoid inline JSON/jsonpath with embedded
# double quotes, which PowerShell mangles when passing arguments to kubectl.exe.
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

$CrdsDirectory = "$PSScriptRoot\manifests\crds"
(Invoke-Kubectl -Params 'delete', '-f', $CrdsDirectory, '--ignore-not-found', '--wait=false').Output | Write-Log

# If the addon has cluster host details recorded (i.e. it knows about an on-node Ceph cluster),
# deleting that cluster is destructive and irreversible, so we ask for an explicit, dedicated
# confirmation (separate from the PVC data prompt above) before tearing it down. If the user
# declines, only the addon/CSI resources are removed and the Ceph cluster on the host node is left
# intact.
$clusterHostNodeIp = if ($Config) { "$($Config.clusterHostNodeIp)".Trim() } else { '' }
$clusterDistribution = if ($Config) { "$($Config.clusterDistribution)".Trim().ToLowerInvariant() } else { '' }

if (-not [string]::IsNullOrWhiteSpace($clusterHostNodeIp)) {
    # Decide whether to delete the on-node Ceph cluster.
    # - Explicit flags win and keep the command non-interactive: -Force deletes, -Keep preserves.
    #   These use the flags as ORIGINALLY passed on the command line, NOT the values set by the
    #   interactive PVC data prompt above (which is a separate decision).
    # - Otherwise always ask for a dedicated confirmation. This mirrors the PVC data prompt above,
    #   which also prompts interactively even when the k2s CLI passes -EncodeStructuredOutput
    #   (Read-Host still works against the console in that mode).
    $deleteCephCluster = $false
    if ($forceFlagProvided) {
        $deleteCephCluster = $true
    }
    elseif ($keepFlagProvided) {
        $deleteCephCluster = $false
    }
    else {
        Write-Log '' -Console
        Write-Log "[Ceph] WARNING: The storage ceph addon has a Ceph cluster recorded on host node '$clusterHostNodeIp'." -Console
        Write-Log '[Ceph] WARNING: This Ceph cluster may already exist and be in use by other workloads.' -Console
        $answer = Read-Host "Do you want to DELETE the Ceph cluster on host node '$clusterHostNodeIp'? This destroys the cluster and ALL its data and cannot be undone. (y/N)"
        if ($answer -eq 'y') {
            $deleteCephCluster = $true
            Write-Log "[Ceph] CEPH CLUSTER DELETION CONFIRMED for host node '$clusterHostNodeIp'." -Console
        }
        else {
            Write-Log "[Ceph] Ceph cluster on host node '$clusterHostNodeIp' will be KEPT." -Console
        }
    }

    if ($deleteCephCluster) {
        if ([string]::IsNullOrWhiteSpace($clusterDistribution)) {
            Write-Log "[Ceph] WARNING: 'clusterDistribution' is missing; skipping on-node Ceph cluster teardown." -Console
        }
        else {
            $removeClusterScript = $null
            switch -Regex ($clusterDistribution) {
                '^debian' { $removeClusterScript = "$PSScriptRoot\scripts\linux\debian\Remove-CephCluster.ps1" }
                default {
                    Write-Log "[Ceph] WARNING: Unsupported clusterDistribution '$clusterDistribution' for teardown; skipping on-node Ceph cluster teardown." -Console
                }
            }

            if ($removeClusterScript -and (Test-Path $removeClusterScript)) {
                Write-Log "[Ceph] Tearing down provisioned Ceph cluster on node '$clusterHostNodeIp' (distribution=$clusterDistribution)" -Console
                & $removeClusterScript -NodeIp $clusterHostNodeIp -Config $Config -ShowLogs:$ShowLogs
                if ($LASTEXITCODE -ne 0) {
                    Write-Log "[Ceph] WARNING: On-node Ceph cluster teardown reported a non-zero exit code ($LASTEXITCODE). Manual cleanup on '$clusterHostNodeIp' may be required." -Console
                }
                else {
                    Write-Log '[Ceph] On-node Ceph cluster teardown completed' -Console
                }
            }
            elseif ($removeClusterScript) {
                Write-Log "[Ceph] WARNING: Teardown script not found at '$removeClusterScript'; skipping on-node Ceph cluster teardown." -Console
            }
        }
    }
    else {
        Write-Log "[Ceph] Only the addon/CSI resources were removed. The Ceph cluster on host node '$clusterHostNodeIp' was NOT deleted." -Console
    }
}

# Remove the local dashboard-access artifacts that Enable.ps1 created so the cephadm dashboard was
# reachable and trusted from this host: the Windows hosts entry (hostname -> node IP) and the
# dashboard's self-signed certificate in the trusted root store.
$dashboardHost = if ($Config -and ($Config.PSObject.Properties.Name -contains 'dashboardHost')) { "$($Config.dashboardHost)".Trim() } else { '' }
$dashboardCertThumbprint = if ($Config -and ($Config.PSObject.Properties.Name -contains 'dashboardCertThumbprint')) { "$($Config.dashboardCertThumbprint)".Trim() } else { '' }

if (-not [string]::IsNullOrWhiteSpace($dashboardHost)) {
    $hostFile = 'C:\Windows\System32\drivers\etc\hosts'
    try {
        if (Test-Path $hostFile) {
            $pattern = '^\s*\S+\s+' + [regex]::Escape($dashboardHost) + '\s*$'
            $content = @(Get-Content -Path $hostFile)
            $filtered = @($content | Where-Object { $_ -notmatch $pattern })
            if ($filtered.Count -ne $content.Count) {
                Set-Content -Path $hostFile -Value $filtered -Encoding ascii -Force
                Write-Log "[Ceph] Removed hosts entry for '$dashboardHost' from '$hostFile'" -Console
            }
        }
    }
    catch {
        Write-Log "[Ceph] WARNING: Failed to remove hosts entry for '$dashboardHost': $($_.Exception.Message)" -Console
    }
}

if (-not [string]::IsNullOrWhiteSpace($dashboardCertThumbprint)) {
    try {
        $certPath = "Cert:\LocalMachine\Root\$dashboardCertThumbprint"
        if (Test-Path $certPath) {
            Remove-Item -Path $certPath -Force
            Write-Log "[Ceph] Removed Ceph dashboard certificate (thumbprint $dashboardCertThumbprint) from trusted root" -Console
        }
    }
    catch {
        Write-Log "[Ceph] WARNING: Failed to remove Ceph dashboard certificate (thumbprint $dashboardCertThumbprint): $($_.Exception.Message)" -Console
    }
}

# Remove the Ceph CSI container images that were pulled onto the K2s cluster node(s) for the CSI
# operator and CephFS driver pods. The k8s resources above only delete the pods; their cached
# images stay in containerd until explicitly removed, so 'crictl images' keeps listing e.g.
# registry.k8s.io/sig-storage/csi-node-driver-registrar after the addon is disabled.
#
# The exact image references are read from the storage addon manifest's ceph 'additionalImages'
# list so this stays in sync with what the addon installs. Only that exact repo:tag list is
# removed (not a broad namespace) so images that other addons might share are not touched by a
# wildcard. These images are re-imported from the offline package on the next enable, so removing
# them here does not break offline reproducibility.
try {
    $storageManifestPath = Join-Path -Path $PSScriptRoot -ChildPath '..\addon.manifest.yaml'
    if (Test-Path $storageManifestPath) {
        # Collect the ceph CSI image references (repo:tag) declared under additionalImages. The
        # smb implementation declares an empty additionalImages list, so only the ceph entries
        # (quay.io/ceph, quay.io/cephcsi, registry.k8s.io/sig-storage) match here.
        $cephImageRefs = @(
            Get-Content -Path $storageManifestPath |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -match '^-\s+(quay\.io/ceph/|quay\.io/cephcsi/|registry\.k8s\.io/sig-storage/)\S+:\S+$' } |
            ForEach-Object { ($_ -replace '^-\s+', '').Trim() } |
            Select-Object -Unique
        )

        if ($cephImageRefs.Count -eq 0) {
            Write-Log '[Ceph] No Ceph CSI images found in storage addon manifest; skipping node image cleanup.'
        }
        else {
            Write-Log "[Ceph] Removing $($cephImageRefs.Count) Ceph CSI image(s) from the K2s cluster node(s)" -Console

            # Enumerate the images actually present on the nodes so we can map each manifest
            # reference to its ContainerImage (with ImageId/Node) for Remove-Image.
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
    }
    else {
        Write-Log "[Ceph] WARNING: Storage addon manifest not found at '$storageManifestPath'; skipping node image cleanup." -Console
    }
}
catch {
    Write-Log "[Ceph] WARNING: Ceph CSI image cleanup on the cluster node(s) failed: $($_.Exception.Message)" -Console
}

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
