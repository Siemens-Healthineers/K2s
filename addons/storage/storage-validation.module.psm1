# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Storage addon validation module

.DESCRIPTION
Provides validation functions to ensure only one storage implementation is enabled at a time.
#>

function Test-StorageImplementationEnabled {
    <#
    .SYNOPSIS
    Check if a specific storage implementation is already enabled

    .PARAMETER Implementation
    Storage implementation name: 'smb' or 'ceph'

    .RETURNS
    $true if implementation is enabled, $false otherwise
    #>
    param(
        [ValidateSet('smb', 'ceph')]
        [string]$Implementation
    )

    switch ($Implementation) {
        'smb' {
            # Check if SMB share is mounted or SMB storage is active
            if (Test-Path 'HKLM:\Software\K2s\Addons\storage') {
                $enabled = Get-ItemProperty -Path 'HKLM:\Software\K2s\Addons\storage' -Name 'smbEnabled' -ErrorAction SilentlyContinue
                if ($enabled -and $enabled.smbEnabled -eq $true) {
                    return $true
                }
            }
            return $false
        }
        'ceph' {
            # Check if Ceph CSI namespaces exist in cluster
            try {
                $ns = kubectl get namespace ceph-csi-rbd -o json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($ns -and $ns.metadata.name -eq 'ceph-csi-rbd') {
                    return $true
                }
            }
            catch {
                return $false
            }
            return $false
        }
        default {
            return $false
        }
    }
}

function Test-ConflictingStorageImplementation {
    <#
    .SYNOPSIS
    Check if a conflicting storage implementation is already enabled

    .PARAMETER RequestedImplementation
    The implementation being requested to enable ('smb' or 'ceph')

    .RETURNS
    Error message if conflict exists, $null if no conflict
    #>
    param(
        [ValidateSet('smb', 'ceph')]
        [string]$RequestedImplementation
    )

    $conflictingImpl = @{
        'smb' = 'ceph'
        'ceph' = 'smb'
    }[$RequestedImplementation]

    if (Test-StorageImplementationEnabled -Implementation $conflictingImpl) {
        return ('Cannot enable storage {0}: {1} storage is already enabled. Please disable {1} storage first using: k2s addons disable storage {1}' -f $RequestedImplementation, $conflictingImpl)
    }

    return $null
}

function Update-StorageImplementationRegistry {
    <#
    .SYNOPSIS
    Update registry to track enabled storage implementation

    .PARAMETER Implementation
    Implementation name ('smb' or 'ceph')

    .PARAMETER Enabled
    $true to mark as enabled, $false to mark as disabled
    #>
    param(
        [ValidateSet('smb', 'ceph')]
        [string]$Implementation,
        [bool]$Enabled
    )

    $regPath = 'HKLM:\Software\K2s\Addons\storage'
    
    # Create registry path if it doesn't exist
    if (-not (Test-Path $regPath)) {
        $null = New-Item -Path $regPath -Force
    }

    $valueName = "$($Implementation)Enabled"
    Set-ItemProperty -Path $regPath -Name $valueName -Value $Enabled -Type DWord
}

Export-ModuleMember -Function @(
    'Test-StorageImplementationEnabled',
    'Test-ConflictingStorageImplementation',
    'Update-StorageImplementationRegistry'
)
