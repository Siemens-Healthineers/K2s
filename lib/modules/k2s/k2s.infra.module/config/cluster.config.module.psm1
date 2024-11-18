# SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT


$pathModule = "$PSScriptRoot\..\..\k2s.infra.module\path\path.module.psm1"
$configModule = "$PSScriptRoot\..\..\k2s.infra.module\config\config.module.psm1"
$fileModule = "$PSScriptRoot\..\..\k2s.infra.module\config\file.module.psm1"
Import-Module $pathModule, $configModule, $fileModule

$k2sConfigDir = Get-K2sConfigDir

#CONSTANTS
New-Variable -Name 'ClusterDescriptorFile' -Value "$k2sConfigDir\cluster.json" -Option Constant

function Get-ClusterDescriptorFilePath {
    return $ClusterDescriptorFile
}

function Set-ConfigInstalledK2sType {
    param (
        [object] $Value = $(throw 'Please provide the config value.')
    )
    Set-ConfigValue -Path $ClusterDescriptorFile -Key 'Name' -Value $Value
}

function Add-NodeConfig {
    param (
        [string]$Name,
        [string]$Role,
        [string]$IpAddress,
        [string]$Username,
        [string]$OS
    )
    $clusterFilePath = Get-ClusterDescriptorFilePath
    $json = Get-JsonContent -FilePath $clusterFilePath
    if (-Not $json) { $json = @{ nodes = @() } }

    $existingNode = $json.nodes | Where-Object { $_.Name -eq $Name }
    if ($existingNode) {
        Write-Error "A node configuration with the name '$Name' already exists."
        return
    }

    $newNode = @{
        Name      = $Name
        Role      = $Role
        IpAddress = $IpAddress
        Username  = $Username
        OS        = $OS
    }
    $json.nodes += $newNode
    Save-JsonContent -JsonObject $json -FilePath $FilePath
    Write-Log "Node '$Name' configuration added successfully." -
}

function Remove-NodeConfig {
    param (
        [string]$Name
    )
    $clusterFilePath = Get-ClusterDescriptorFilePath
    $json = Get-JsonContent -FilePath $clusterFilePath
    if (-Not $json) { return }

    $nodeToRemove = $json.nodes | Where-Object { $_.Name -eq $Name }
    if (-Not $nodeToRemove) {
        Write-Log "No node configuration found with the name '$Name'."
        return
    }

    $json.nodes = $json.nodes | Where-Object { $_.Name -ne $Name }
    Save-JsonContent -JsonObject $json -FilePath $FilePath
    Write-Log "Node '$Name' configuration removed successfully."
}

<#
Update-NodeConfig -Name "gtry22c" -Updates @{
    Role = "master"
    IpAddress = "172.19.1.104"
    OS = "windows"
}
#>
function Update-NodeConfig {
    param (
        [string]$Name,
        [hashtable]$Updates
    )
    $clusterFilePath = Get-ClusterDescriptorFilePath
    $json = Get-JsonContent -FilePath $clusterFilePath
    if (-Not $json) { return }

    $nodeToUpdate = $json.nodes | Where-Object { $_.Name -eq $Name }
    if (-Not $nodeToUpdate) {
        Write-Log "No node configuration found with the name '$Name'."
        return
    }

    foreach ($key in $Updates.Keys) {
        if ($nodeToUpdate.PSObject.Properties[$key]) {
            $nodeToUpdate.$key = $Updates[$key]
        }
        else {
            Write-Log "Property '$key' does not exist on the node. Skipping."
        }
    }

    Save-JsonContent -JsonObject $json -FilePath $FilePath
    Write-Log "Node '$Name' configuration updated successfully."
}

Export-ModuleMember -Function Add-NodeConfig, Remove-NodeConfig, Update-NodeConfig
