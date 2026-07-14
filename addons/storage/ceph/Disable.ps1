# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
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

$gatewayApiCrds = "$PSScriptRoot\common\manifests\crds\crd.yaml"
(Invoke-Kubectl -Params 'delete', '--ignore-not-found', '--timeout=30s', '-f', $gatewayApiCrds).Output | Write-Log

# Mark Ceph as disabled in registry
Update-StorageImplementationRegistry -Implementation 'ceph' -Enabled $false

# Remove the addon (with its implementation) from setup.json so that 'k2s addons ls' no longer
# reports it as enabled and Test-IsAddonEnabled returns false.
Remove-AddonFromSetupJson -Addon ([pscustomobject] @{Name = $addonName; Implementation = 'ceph' })

Write-Log "[Ceph] Addon disabled successfully" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{
        Error = $null
        Status = "Storage ceph addon disabled successfully"
        AddonName = $addonName
        DataAction = if ($Force) { "deleted" } elseif ($Keep) { "preserved" } else { "prompted" }
    }
}
