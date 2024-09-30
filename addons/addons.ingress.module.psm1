# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

$infraModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
$nodeModule = "$PSScriptRoot/../lib/modules/k2s/k2s.node.module/k2s.node.module.psm1"
$addonsModule = "$PSScriptRoot\addons.module.psm1"

Import-Module $infraModule, $clusterModule, $nodeModule, $addonsModule

$updateIngressConfigAnnotation = 'k2s.cluster.local/update-ingress-configuration'

function Update-IngressForAddons {
    Write-Log "Adapting ingress entries for addons" -Console

    $allManifests = Find-AddonManifests -Directory $PSScriptRoot |`
        ForEach-Object { 
        $manifest = Get-FromYamlFile -Path $_ 
        $manifest
    }

    $addons = Get-AddonsConfig
    $addons | ForEach-Object {
        $addon = $_.Name
        $addonConfig = Get-AddonConfig -Name $addon
        if ($null -eq $addonConfig) {
            Write-Log "Addon '$($addon.Name)' not found in config, skipping.." -Console
            return
        }

        $manifest = $allManifests | Where-Object { $_.metadata.name -eq $addon}
        if ($null -ne $manifest.metadata.annotations.$updateIngressConfigAnnotation -and $manifest.metadata.annotations.$updateIngressConfigAnnotation -eq "true") {
            Write-Log "  Updating $addon addon ..." -Console
            Update-IngressForAddon -Addon ([pscustomobject] @{Name = $addonConfig.Name; Implementation = $addonConfig.Implementation })
        }
    }
    Write-Log 'Addons have been adapted to new ingress configuration' -Console
}

<#
.DESCRIPTION
Updates the ingress manifest for an addon based on the ingress controller detected in the cluster.
#>
function Update-IngressForAddon {
    param (
        [Parameter(Mandatory = $false)]
        [pscustomobject]$Addon = $(throw 'Please specify the addon.')
    )

    if (Test-NginxIngressControllerAvailability) {
        Remove-IngressForTraefik -Addon $Addon
        Update-IngressForNginx -Addon $Addon
    }
    elseif (Test-TraefikIngressControllerAvailability) {
        Remove-IngressForNginx -Addon $Addon
        Update-IngressForTraefik -Addon $Addon
    }
    else {
        Remove-IngressForNginx -Addon $Addon
        Remove-IngressForTraefik -Addon $Addon
    }
}

<#
.DESCRIPTION
Determines if Nginx ingress controller is deployed in the cluster
#>
function Test-NginxIngressControllerAvailability {
    $existingServices = (Invoke-Kubectl -Params 'get', 'service', '-n', 'ingress-nginx', '-o', 'yaml').Output 
    if ("$existingServices" -match '.*ingress-nginx-controller.*') {
        return $true
    }
    return $false
}

<#
.DESCRIPTION
Determines if Traefik ingress controller is deployed in the cluster
#>
function Test-TraefikIngressControllerAvailability {
    $existingServices = (Invoke-Kubectl -Params 'get', 'service', '-n', 'ingress-traefik', '-o', 'yaml').Output
    if ("$existingServices" -match '.*traefik.*') {
        return $true
    }
    return $false
}

<#
.DESCRIPTION
Determines if KeyCloak is deployed in the cluster
#>
function Test-KeyCloakServiceAvailability {
    $existingServices = (Invoke-Kubectl -Params 'get', 'service', '-n', 'security', '-o', 'yaml').Output
    if ("$existingServices" -match '.*keycloak.*') {
        return $true
    }
    return $false
}

<#
.DESCRIPTION
Enables a ingress addon based on the input
#>
function Enable-IngressAddon([string]$Ingress) {
    switch ($Ingress) {
        'nginx' {
            &"$PSScriptRoot\ingress\nginx\Enable.ps1"
            break
        }
        'traefik' {
            &"$PSScriptRoot\ingress\traefik\Enable.ps1"
            break
        }
    }
}

<#
.DESCRIPTION
Gets the location of traefik ingress yaml
#>
function Get-IngressTraefikConfig {
    param (
        [Parameter(Mandatory = $false)]
        [string]$Directory = $(throw 'Directory of the ingress traefik config')
    )
    return "$PSScriptRoot\$Directory\manifests\ingress-traefik"
}

<#
.DESCRIPTION
Gets the location of nginx ingress yaml
#>
function Get-IngressNginxConfig {
    param (
        [Parameter(Mandatory = $false)]
        [string]$Directory = $(throw 'Directory of the ingress nginx config')
    )
    return "$PSScriptRoot\$Directory\manifests\ingress-nginx"
}

<#
.DESCRIPTION
Gets the location of nginx secure ingress yaml
#>
function Get-IngressNginxSecureConfig {
    param (
        [Parameter(Mandatory = $false)]
        [string]$Directory = $(throw 'Directory of the ingress nginx secure config')
    )
    return "$PSScriptRoot\$Directory\manifests\ingress-nginx-secure"
}

<#
.DESCRIPTION
Deploys the addon's ingress manifest for Nginx ingress controller
#>
function Update-IngressForNginx {
    param (
        [Parameter(Mandatory = $false)]
        [pscustomobject]$Addon = $(throw 'Please specify the addon.')
    )

    $props = Get-AddonProperties -Addon $Addon

    if (Test-KeyCloakServiceAvailability) {
        Write-Log "  Applying secure nginx ingress manifest for $($props.Name)..." -Console
        $kustomizationDir = Get-IngressNginxSecureConfig -Directory $props.Directory
    }
    else {
        Write-Log "  Applying nginx ingress manifest for $($props.Name)..." -Console
        $kustomizationDir = Get-IngressNginxConfig -Directory $props.Directory
        
    }
    Invoke-Kubectl -Params 'apply', '-k', $kustomizationDir | Out-Null
}

<#
.DESCRIPTION
Delete the addon's ingress manifest for Nginx ingress controller
#>
function Remove-IngressForNginx {
    param (
        [Parameter(Mandatory = $false)]
        [pscustomobject]$Addon = $(throw 'Please specify the addon.')
    )

    $props = Get-AddonProperties -Addon $Addon
    
    Write-Log "  Deleting nginx ingress manifest for $($props.Name)..." -Console
    # SecureNginxConfig is a superset of NginsConfig, so we delete that:
    $kustomizationDir = Get-IngressNginxSecureConfig -Directory $props.Directory
    Invoke-Kubectl -Params 'delete', '-k', $kustomizationDir | Out-Null
}

<#
.DESCRIPTION
Deploys the addon's ingress manifest for Traefik ingress controller
#>
function Update-IngressForTraefik {
    param (
        [Parameter(Mandatory = $false)]
        [pscustomobject]$Addon = $(throw 'Please specify the addon.')
    )

    $props = Get-AddonProperties -Addon $Addon

    Write-Log "  Applying traefik ingress manifest for $($props.Name)..." -Console
    $ingressTraefikConfig = Get-IngressTraefikConfig -Directory $props.Directory
    
    Invoke-Kubectl -Params 'apply', '-k', $ingressTraefikConfig | Out-Null
}

<#
.DESCRIPTION
Delete the addon's ingress manifest for Traefik ingress controller
#>
function Remove-IngressForTraefik {
    param (
        [Parameter(Mandatory = $false)]
        [pscustomobject]$Addon = $(throw 'Please specify the addon.')
    )

    $props = Get-AddonProperties -Addon $Addon

    Write-Log "  Deleting traefik ingress manifest for $($props.Name)..." -Console
    $ingressTraefikConfig = Get-IngressTraefikConfig -Directory $props.Directory
    
    Invoke-Kubectl -Params 'delete', '-k', $ingressTraefikConfig | Out-Null
}

function Get-AddonProperties {
    param (
        [Parameter(Mandatory = $false)]
        [pscustomobject]$Addon = $(throw 'Please specify the addon.')
    )
    if ($Addon -eq $null) {
        throw 'Addon not specified'
    }
    if ($null -eq ($Addon | Get-Member -MemberType Properties -Name 'Name')) {
        throw "Addon does not contain a property with name 'Name'"
    }

    $addonName = $Addon.Name
    $directory = $Addon.Name
    if ($null -ne $Addon.Implementation) {
        $addonName += " $($Addon.Implementation)"
        $directory += "\$($Addon.Implementation)"
    }

    return [pscustomobject]@{Name = $addonName; Directory = $directory }
}

Export-ModuleMember -Function Update-IngressForAddons, Update-IngressForAddon, Test-NginxIngressControllerAvailability, Test-TraefikIngressControllerAvailability,
Enable-IngressAddon, Remove-IngressForTraefik, Remove-IngressForNginx