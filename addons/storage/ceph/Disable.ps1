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

function Clear-CephFinalizers {
    # Proactively removes all operator-managed finalizers from Ceph CRD instances
    # and the CRDs themselves so that subsequent deletes never block.
    param(
        [string[]]$Namespaces,
        [string[]]$CrdNames
    )

    foreach ($ns in $Namespaces) {
        $nsExists = (& kubectl get namespace $ns --ignore-not-found -o name 2>$null)
        if ([string]::IsNullOrWhiteSpace($nsExists)) { continue }

        foreach ($crd in $CrdNames) {
            $instances = (& kubectl get $crd -n $ns -o name --ignore-not-found 2>$null)
            foreach ($instance in ($instances -split "`r?`n" | Where-Object { $_ -ne '' })) {
                & kubectl patch $instance -n $ns --type=merge -p '{"metadata":{"finalizers":null}}' 2>$null | Out-Null
            }
        }
    }

    foreach ($crd in $CrdNames) {
        & kubectl patch crd $crd --type=merge -p '{"metadata":{"finalizers":null}}' 2>$null | Out-Null
    }
}

function Remove-NamespaceFinalizer {
    # Last-resort: force-finalize a namespace that is stuck in Terminating.
    param([string]$Namespace)

    $nsJson = (& kubectl get namespace $Namespace -o json 2>$null)
    if ([string]::IsNullOrWhiteSpace($nsJson)) { return }

    $tmpFile = Join-Path ([System.IO.Path]::GetTempPath()) ("k2s-ceph-ns-$Namespace.json")
    try {
        $obj = $nsJson | ConvertFrom-Json
        $obj.spec.finalizers = @()
        $obj | ConvertTo-Json -Depth 100 | Out-File -FilePath $tmpFile -Encoding Ascii
        & kubectl replace --raw "/api/v1/namespaces/$Namespace/finalize" -f $tmpFile 2>&1 | Write-Log
    }
    finally {
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
    }
}

Write-Log "[Ceph] Disabling Ceph CSI storage addon" -Console

$addonName = Get-AddonNameFromFolderPath -BaseFolderPath $PSScriptRoot

# Check for PersistentVolumes if no flag provided
if (-not $Force -and -not $Keep) {
    Write-Log "[Ceph] Checking for PersistentVolumes" -Console
    $pvs = @(kubectl get pv -o json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue | Select-Object -ExpandProperty items | Where-Object { $_.spec.storageClassName -like "ceph-*" } 2>$null)
    
    if ($pvs.Count -gt 0) {
        Write-Log "[Ceph] Found $($pvs.Count) PersistentVolumes using Ceph storage" -Console
        Write-Log "[Ceph] Options: 1) Delete all data, 2) Keep all data, 3) Cancel" -Console
        
        $choice = $null
        while (-not $choice) {
            $choice = Read-Host "Enter your choice (1/2/3)"
            if ($choice -eq "1") {
                $Force = $true
            }
            elseif ($choice -eq "2") {
                $Keep = $true
            }
            elseif ($choice -eq "3") {
                Write-Log "[Ceph] Addon disable cancelled" -Console
                if ($EncodeStructuredOutput -eq $true) {
                    Send-ToCli -MessageType $MessageType -Message @{Error = (New-Error -Code 'op-cancelled-by-user' -Message "Operation cancelled by user") }
                }
                return
            }
            else {
                Write-Log "[Ceph] Invalid choice. Please enter 1, 2, or 3." -Console -Error
                $choice = $null
            }
        }
    }
}

$cephManifestsDir = "$PSScriptRoot\manifests"
$cephKustomization = "$cephManifestsDir\kustomization.yaml"
$cephCrdsManifest = "$cephManifestsDir\crds\crd.yaml"
$cephNamespaces = @('ceph-csi-operator-system', 'ceph-csi-cephfs')
$legacyCephNamespaces = @('ceph-csi-rbd')
$cephCrds = @('cephconnections.csi.ceph.io', 'clientprofiles.csi.ceph.io', 'clientprofilemappings.csi.ceph.io')

# Clear operator-managed finalizers before any deletes so nothing can block
Write-Log "[Ceph] Clearing Ceph operator finalizers" -Console
Clear-CephFinalizers -Namespaces $cephNamespaces -CrdNames $cephCrds

Write-Log "[Ceph] Removing Ceph CSI operator manifests" -Console
if (Test-Path -Path $cephKustomization) {
    $kustomizationWorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("k2s-ceph-kustomize-delete-" + [guid]::NewGuid().ToString())
    New-Item -Path $kustomizationWorkDir -ItemType Directory -ErrorAction Stop | Out-Null
    Copy-Item -Path (Join-Path $cephManifestsDir '*') -Destination $kustomizationWorkDir -Recurse -Force

    $runtimeKustomization = @(
        'apiVersion: kustomize.config.k8s.io/v1beta1',
        'kind: Kustomization',
        '',
        'resources:',
        '  - csi-rbac.yaml',
        '  - operator.yaml',
        '  - cephfs-driver.yaml',
        '  - ceph-connection.yaml',
        '  - client-profile.yaml'
    )
    Set-Content -Path (Join-Path $kustomizationWorkDir 'kustomization.yaml') -Value ($runtimeKustomization -join "`r`n") -Encoding UTF8

    & kubectl delete -k "$kustomizationWorkDir" --ignore-not-found=true 2>&1 | Write-Log
    Remove-Item -Path $kustomizationWorkDir -Recurse -Force -ErrorAction SilentlyContinue
}
else {
    Write-Log "[Ceph] WARNING: Ceph kustomization not found at $cephKustomization" -Console
}

Write-Log "[Ceph] Removing Ceph CSI CRDs" -Console
if (Test-Path -Path $cephCrdsManifest) {
    & kubectl delete -f "$cephCrdsManifest" --ignore-not-found=true 2>&1 | Write-Log
}
else {
    Write-Log "[Ceph] WARNING: Ceph CRD manifest not found at $cephCrdsManifest" -Console
}

Write-Log "[Ceph] Removing Ceph CSI provisioners" -Console
& kubectl delete namespace $cephNamespaces --ignore-not-found=true 2>&1 | Write-Log
& kubectl delete namespace $legacyCephNamespaces --ignore-not-found=true 2>&1 | Write-Log
if (-not $Keep) {
    & kubectl delete storageclass ceph-rbd ceph-cephfs --ignore-not-found=true 2>$null | Out-Null
}

# Wait for namespaces to be fully gone; if a namespace controller is still stuck,
# force-clear its finalizer as a last resort.
$nsArgs = ($cephNamespaces + $legacyCephNamespaces) | ForEach-Object { "namespace/$_" }
& kubectl wait --for=delete $nsArgs --timeout=120s 2>$null
foreach ($ns in ($cephNamespaces + $legacyCephNamespaces)) {
    $still = (& kubectl get namespace $ns --ignore-not-found -o name 2>$null)
    if (-not [string]::IsNullOrWhiteSpace($still)) {
        Write-Log "[Ceph] Namespace '$ns' still terminating; forcing namespace finalizer removal" -Console
        Remove-NamespaceFinalizer -Namespace $ns
    }
}

# Mark Ceph as disabled in registry
Update-StorageImplementationRegistry -Implementation 'ceph' -Enabled $false

Write-Log "[Ceph] Addon disabled successfully" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{
        Error = $null
        Status = "Ceph CSI addon disabled successfully"
        AddonName = $addonName
        DataAction = if ($Force) { "deleted" } elseif ($Keep) { "preserved" } else { "prompted" }
    }
}
