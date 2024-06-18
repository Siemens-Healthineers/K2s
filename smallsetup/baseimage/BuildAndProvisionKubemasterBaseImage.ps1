# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

param (
    [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of VM')]
    [long]$VMMemoryStartupBytes,
    [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for VM')]
    [long]$VMProcessorCount,
    [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of VM')]
    [uint64]$VMDiskSize,
    [parameter(Mandatory = $false, HelpMessage = 'The HTTP proxy if available.')]
    [string]$Proxy = '',
    [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
    [ValidateScript({ Assert-Pattern -Path $_ -Pattern ".*\.vhdx$" })]
    [parameter(Mandatory = $false, HelpMessage = 'The path to save the provisioned base image.')]
    [string] $OutputPath = $(throw "Argument missing: OutputPath")
    )

    Assert-Path -Path (Split-Path $OutputPath) -PathType "Container" -ShallExist $true | Out-Null

    $infraModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
    $nodeModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.node.module\k2s.node.module.psm1"
    Import-Module $infraModule, $nodeModule

    if (Test-Path -Path $OutputPath) {
	    Remove-Item -Path $OutputPath -Force
        Write-Log "Deleted already existing provisioned image '$OutputPath'"
    } else {
        Write-Log "Provisioned image '$OutputPath' does not exist. Nothing to delete."
    }

    $baseDirectory = $(Split-Path -Path $OutputPath)
    $rootfsPath = "$baseDirectory\$(Get-ControlPlaneOnWslRootfsFileName)"
    if (Test-Path -Path $rootfsPath) {
	    Remove-Item -Path $rootfsPath -Force
        Write-Log "Deleted already existing file for WSL support '$rootfsPath'"
    } else {
        Write-Log "File for WSL support '$rootfsPath' does not exist. Nothing to delete."
    }

    $hostname = Get-ConfigControlPlaneNodeHostname
    $ipAddress = Get-ConfiguredIPControlPlane
    $gatewayIpAddress = Get-ConfiguredKubeSwitchIP
    $loopbackAdapter = Get-L2BridgeName
    $dnsServers = Get-DnsIpAddressesFromActivePhysicalNetworkInterfacesOnWindowsHost -ExcludeNetworkInterfaceName $loopbackAdapter
    if ([string]::IsNullOrWhiteSpace($dnsServers)) {
        $dnsServers = '8.8.8.8'
    }

    $controlPlaneNodeCreationParams = @{
        Hostname=$hostname
        IpAddress=$ipAddress
        GatewayIpAddress=$gatewayIpAddress
        DnsServers= $dnsServers
        VmImageOutputPath=$OutputPath
        Proxy=$Proxy
        VMMemoryStartupBytes=$VMMemoryStartupBytes
        VMProcessorCount=$VMProcessorCount
        VMDiskSize=$VMDiskSize
    }
    New-VmImageForControlPlaneNode @controlPlaneNodeCreationParams

    if (!(Test-Path -Path $OutputPath)) {
        throw "The file '$OutputPath' was not created"
    }

    $wslRootfsForControlPlaneNodeCreationParams = @{
        VmImageInputPath = $OutputPath
        RootfsFileOutputPath = $rootfsPath
        Proxy = $Proxy
        VMMemoryStartupBytes=$VMMemoryStartupBytes
        VMProcessorCount=$VMProcessorCount
        VMDiskSize=$VMDiskSize
    }

    New-WslRootfsForControlPlaneNode @wslRootfsForControlPlaneNodeCreationParams

    if (!(Test-Path -Path $rootfsPath)) {
        throw "The file '$rootfsPath' was not created"
    }