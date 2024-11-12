# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Windows ISO image path (mandatory if not Linux-only)')]
    [string] $WindowsImage = $(throw "Argument missing: WindowsImage"),
    [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of Windows VM')]
    [long] $WinVMStartUpMemory = 4GB,
    [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of Windows VM')]
    [long] $WinVMDiskSize = 50GB,
    [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors of Windows VM')]
    [long] $WinVMProcessorCount = 4,
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy,
    [parameter(HelpMessage = 'DNS Addresses')]
    [string]$DnsAddresses = $(throw 'Argument missing: DnsAddresses'),
    [parameter(Mandatory = $false, HelpMessage = 'Do not call the StartK8s at end')]
    [switch] $SkipStart = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
    [switch] $DeleteFilesForOfflineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Force the installation online. This option is needed if the files for an offline installation are available but you want to recreate them.')]
    [switch] $ForceOnlineInstallation = $false
)

$installStopwatch = [system.diagnostics.stopwatch]::StartNew()

$infraModule =   "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule =    "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"

Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

$ErrorActionPreference = 'Continue'

# make sure we are at the right place for install
$installationPath = Get-KubePath
Set-Location $installationPath

if (!(Test-Path -Path $WindowsImage)) {
    throw "Windows image ISO file '$WindowsImage' not found."
}

$workerNodeParams = @{
    Image = $WindowsImage
    Hostname = $(Get-ConfigVMNodeHostname)
    VmName = $(Get-ConfigVMNodeHostname)
    IpAddress = $(Get-WindowsVmIpAddress)
    DnsAddresses = $DnsAddresses
    VMStartUpMemory = $WinVMStartUpMemory
    VMDiskSize = $WinVMDiskSize
    VMProcessorCount = $WinVMProcessorCount
    Proxy = $Proxy
    AdditionalHooksDir = $AdditionalHooksDir
    DeleteFilesForOfflineInstallation = $DeleteFilesForOfflineInstallation
    ForceOnlineInstallation = $ForceOnlineInstallation
}
Add-WindowsWorkerNodeOnNewVM @workerNodeParams

if (! $SkipStart) {
    Write-Log 'Starting Windows worker node on Hyper-V VM'
    & "$PSScriptRoot\Start.ps1" -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs -HideHeaders:$true -DnsAddresses $DnsAddresses

    if ($RestartAfterInstallCount -gt 0) {
        $restartCount = 0;
    
        while ($true) {
            $restartCount++
            Write-Log "Restarting Windows worker node on Hyper-V VM (iteration #$restartCount):"
    
            & "$PSScriptRoot\Stop.ps1" -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs -HideHeaders:$true
            Start-Sleep 10 # Wait for renew of IP
    
            & "$PSScriptRoot\Start.ps1" -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs -HideHeaders:$true -DnsAddresses $DnsAddresses
            Start-Sleep -s 5
    
            if ($restartCount -eq $RestartAfterInstallCount) {
                Write-Log 'Restarting Windows worker node on Hyper-V VM completed'
                break;
            }
        }
    }
} else {
    & "$PSScriptRoot\Stop.ps1" -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs -HideHeaders:$true
}

Invoke-Hook -HookName 'AfterWorkerNodeOnVMInstall' -AdditionalHooksDir $AdditionalHooksDir

Write-Log '---------------------------------------------------------------'
Write-Log "K2s Windows worker node on Hyper-V VM setup finished.   Total duration: $('{0:hh\:mm\:ss}' -f $installStopwatch.Elapsed )"
Write-Log '---------------------------------------------------------------'

