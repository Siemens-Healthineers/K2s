# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Do not call the StartK8s at end')]
    [switch] $SkipStart = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy,
    [parameter(Mandatory = $false, HelpMessage = 'Target machine IP address')]
    [string] $IpAddress,  # Add this parameter
    [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
    [switch] $DeleteFilesForOfflineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Force the installation online. This option is needed if the files for an offline installation are available but you want to recreate them.')]
    [switch] $ForceOnlineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'The path to local builds of Kubernetes binaries')]
    [string] $K8sBinsPath = ''
)

$installStopwatch = [system.diagnostics.stopwatch]::StartNew()

$infraModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"

Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

# Replace the Write-Log line (around line 32) with this:
Write-Log "InstallNode.ps1 started. IPAddress: $IpAddress ShowLogs: $ShowLogs"

# Read join command from file
$joinCommandFile = "C:\Temp\join-command.txt"
if (Test-Path $joinCommandFile) {
    $JoinCommand = Get-Content -Path $joinCommandFile -Raw -Encoding UTF8
    $JoinCommand = $JoinCommand.Trim()
    Write-Log "Join command read from file: $joinCommandFile"
} else {
    Write-Log "Join command file not found at: $joinCommandFile. Will generate new join command." -Console
    $JoinCommand = $null
}

$ErrorActionPreference = 'Continue'

# make sure we are at the right place for install
$installationPath = Get-KubePath
Set-Location $installationPath

Write-Log "Setting up Windows worker node"

$windowsHostIpAddress = Get-ConfiguredKubeSwitchIP
$transparentProxy = "http://$($windowsHostIpAddress):8181"
#$joinCommand = New-JoinCommand

$workerNodeParams = @{
    Proxy                             = $transparentProxy
    AdditionalHooksDir                = $AdditionalHooksDir
    DeleteFilesForOfflineInstallation = $DeleteFilesForOfflineInstallation
    ForceOnlineInstallation           = $ForceOnlineInstallation
    PodSubnetworkNumber               = '2'
    JoinCommand                       = $JoinCommand
    K8sBinsPath                       = $K8sBinsPath
    IpAddress                         = $IpAddress
}
Add-WindowsWorkerNodeOnWindowsHost @workerNodeParams

# Verify loopback adapter has IP address before proceeding
Write-Log 'Verifying loopback adapter configuration...'
$maxRetries = 10
$retryCount = 0
$adapterConfigured = $false

while ($retryCount -lt $maxRetries -and -not $adapterConfigured) {
    try {
        # Import the required module to access Get-L2BridgeName
        $loopbackModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.node.module\windowsnode\network\loopbackadapter.module.psm1"
        Import-Module $loopbackModule -Force
        
        $adapterName = Get-L2BridgeName
        $ipAddress = Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias $adapterName -ErrorAction Stop
        if ($ipAddress) {
            Write-Log "Loopback adapter '$adapterName' successfully configured with IP: $($ipAddress.IPAddress)" -Console
            $adapterConfigured = $true
        }
    }
    catch {
        $retryCount++
        Write-Log "Attempt $retryCount of ${maxRetries}: Waiting for loopback adapter IP configuration... Error: $($_.Exception.Message)" -Console
        Start-Sleep -Seconds 2
        
        # Try to reconfigure the adapter on retry 5
        if ($retryCount -eq 5) {
            Write-Log "Re-attempting loopback adapter configuration..." -Console
            try {
                New-DefaultLoopbackAdapter
            }
            catch {
                Write-Log "Failed to reconfigure loopback adapter: $($_.Exception.Message)" -Console
            }
        }
    }
}

if (-not $adapterConfigured) {
    throw "Failed to configure loopback adapter after $maxRetries attempts. Please check network configuration."
}

Write-Log "Starting Windows worker node on Windows host"
$dnsServers = '8.8.8.8,8.8.4.4'  # Use default DNS servers
$startWorkerParams = @{
    PodSubnetworkNumber = '2'
    DnsServers = $dnsServers
    AdditionalHooksDir = $AdditionalHooksDir
    SkipHeaderDisplay = $true
}
Start-WindowsWorkerNodeOnWindowsHost @startWorkerParams

Write-Log "Join Command after installation:" -Console
if ([string]::IsNullOrWhiteSpace($JoinCommand)) {
    $JoinCommand = New-JoinCommand
    Write-Log "Generated new join command: $JoinCommand" -Console
} else {
    Write-Log "Using provided join command: $JoinCommand" -Console
}
#Write-Log "Initialize-KubernetesCluster: $IpAddress"
#Initialize-KubernetesCluster -AdditionalHooksDir $AdditionalHooksDir -PodSubnetworkNumber $PodSubnetworkNumber -JoinCommand $JoinCommand -IpAddress $IpAddress
# Write-Log 'Adding mirror registries'
# $mirrorRegistries = Get-MirrorRegistries
# foreach ($registry in $mirrorRegistries) {
#     Set-Registry -Name $registry.registry -Https -SkipVerify -Mirror $registry.mirror -Server $registry.server 
# }

# if (! $SkipStart) {
#     Write-Log 'Starting Windows worker node on Windows host'
#     & "$PSScriptRoot\Start.ps1" -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs -HideHeaders:$true -DnsAddresses $DnsAddresses

#     if ($RestartAfterInstallCount -gt 0) {
#         $restartCount = 0;
    
#         while ($true) {
#             $restartCount++
#             Write-Log "Restarting Windows worker node on Windows host (iteration #$restartCount):"
    
#             & "$PSScriptRoot\Stop.ps1" -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs -HideHeaders:$true
#             Start-Sleep 10
    
#             & "$PSScriptRoot\Start.ps1" -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs -HideHeaders:$true -DnsAddresses $DnsAddresses
#             Start-Sleep -s 5
    
#             if ($restartCount -eq $RestartAfterInstallCount) {
#                 Write-Log 'Restarting Windows worker node on Windows host completed'
#                 break;
#             }
#         }
#     }
# }
# else {
#     & "$PSScriptRoot\Stop.ps1" -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs -HideHeaders:$true
# }

Write-Log '---------------------------------------------------------------'
Write-Log "K2s Windows worker node on Windows host setup finished.   Total duration: $('{0:hh\:mm\:ss}' -f $installStopwatch.Elapsed )"
Write-Log '---------------------------------------------------------------'



