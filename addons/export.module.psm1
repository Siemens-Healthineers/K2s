# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$infraModule = "$PSScriptRoot/../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"

Import-Module $infraModule

$binPath = Get-KubeBinPath
$nerdctlExe = "$binPath\nerdctl.exe"
$crictlExe = "$binPath\crictl.exe"

function Get-NerdctlExe {
    return $nerdctlExe    
}

function Get-CrictlExe {
    return $crictlExe    
}

function Update-ManifestForSingleImplementation {
    param(
        [string]$ManifestPath,
        [string]$ImplementationName,
        [string]$K2sVersion
    )
    
    if (-not (Test-Path $ManifestPath)) {
        Write-Log "Manifest not found: $ManifestPath" -Error
        return
    }
    
    try {
        $manifest = Get-FromYamlFile -Path $ManifestPath
        
        # Filter to keep only the specified implementation
        $targetImpl = $manifest.spec.implementations | Where-Object { $_.name -eq $ImplementationName }
        if (-not $targetImpl) {
            Write-Log "Implementation '$ImplementationName' not found in manifest" -Error
            return
        }
        
        # Update manifest to contain only the target implementation
        $manifest.spec.implementations = @($targetImpl)
        
        # Add export metadata annotations
        if (-not $manifest.metadata.annotations) {
            $manifest.metadata.annotations = @{}
        }
        $manifest.metadata.annotations["k2s.io/exported-implementation"] = $ImplementationName
        $manifest.metadata.annotations["k2s.io/export-date"] = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        $manifest.metadata.annotations["k2s.io/exported-version"] = $K2sVersion
        $manifest.metadata.annotations["k2s.io/export-type"] = "single-implementation"
        
        # Save updated manifest
        $manifest | ConvertTo-Yaml | Set-Content -Path $ManifestPath -Force
        Write-Log "Updated manifest for single implementation: $ImplementationName"
        
    } catch {
        Write-Log "Failed to update manifest: $_" -Error
    }
}

Export-ModuleMember -Function Get-NerdctlExe, Get-CrictlExe, Update-ManifestForSingleImplementation
