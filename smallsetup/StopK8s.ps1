# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Cache vSwitches on stop')]
    [switch] $CacheK2sVSwitches
)

# load global settings
&$PSScriptRoot\common\GlobalVariables.ps1

# import global functions
. $PSScriptRoot\common\GlobalFunctions.ps1

Import-Module "$PSScriptRoot/ps-modules/log/log.module.psm1"

Initialize-Logging -ShowLogs:$ShowLogs

# make sure we are at the right place for executing this script
Set-Location $global:KubernetesPath

if ($global:HeaderLineShown -ne $true) {
    Write-Log 'Stopping K2s'
}

# reset default namespace
if (Test-Path $global:KubectlExe) {
    Write-Log 'Resetting default namespace for kubernetes'
    &$global:KubectlExe config set-context --current --namespace=default | Out-Null
}

$ProgressPreference = 'SilentlyContinue'

$WSL = Get-WSLFromConfig

Write-Log 'Stopping K8s services' -Console

Stop-ServiceAndSetToManualStart 'kubeproxy'
Stop-ServiceAndSetToManualStart 'kubelet'
Stop-ServiceAndSetToManualStart 'flanneld'
Stop-ServiceAndSetToManualStart 'windows_exporter'
Stop-ServiceAndSetToManualStart 'containerd'
Stop-ServiceAndSetToManualStart 'httpproxy'
Stop-ServiceAndSetToManualStart 'dnsproxy'

$shallRestartDocker = $false
if ($(Get-Service -Name 'docker' -ErrorAction SilentlyContinue).Status -eq 'Running') {
    Stop-ServiceProcess 'docker' 'dockerd'
    $shallRestartDocker = $true
}

Write-Log "Stopping $global:VMName VM" -Console

$isReusingExistingLinuxComputer = Get-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_ReuseExistingLinuxComputerForMasterNode

if ($WSL) {
    wsl --shutdown
    Remove-NetIPAddress -IPAddress $global:IP_NextHop -PrefixLength 24 -Confirm:$False -ErrorAction SilentlyContinue
    Reset-DnsServer $global:WSLSwitchName

}
elseif ($isReusingExistingLinuxComputer) {
    $switchName = get-netipaddress -IPAddress $global:IP_NextHop | Select-Object -ExpandProperty 'InterfaceAlias'
    Reset-DnsServer $switchName
}
else {
    # stop vm
    if ($(Get-VM | Where-Object Name -eq $global:VMName | Measure-Object).Count -eq 1 ) {
        Write-Log ('Stopping VM: ' + $global:VMName)
        Stop-VM -Name $global:VMName -Force -WarningAction SilentlyContinue
    }
}

Write-Log 'Stopping K8s network' -Console
Restart-WinService 'hns'

Invoke-Hook -HookName 'BeforeStopK8sNetwork' -AdditionalHooksDir $AdditionalHooksDir

if (!$CacheK2sVSwitches) {
    # remove kubeswitch
    Remove-KubeSwitch

    # Remove the external switch
    RemoveExternalSwitch
}

# remove NAT
Remove-NetNat -Name $global:NetNatName -Confirm:$False -ErrorAction SilentlyContinue

$hns = $(Get-HNSNetwork)
# there's always at least the Default Switch network available, so we check for >= 2
if ($($hns | Measure-Object).Count -ge 2) {
    Write-Log 'Delete bridge, clear HNSNetwork (short disconnect expected)'
    if(!$CacheK2sVSwitches) { 
         $hns | Where-Object Name -Like '*cbr0*' | Remove-HNSNetwork -ErrorAction SilentlyContinue
         $hns | Where-Object Name -Like ('*' + $global:SwitchName + '*') | Remove-HNSNetwork -ErrorAction SilentlyContinue
    }
}

if ($WSL) {
    $hns | Where-Object Name -Like ('*' + $global:WSLSwitchName + '*') | Remove-HNSNetwork -ErrorAction SilentlyContinue
    Restart-WinService 'WslService'
}

Write-Log 'Delete network policies'
if(!$CacheK2sVSwitches) { 
    Get-HnsPolicyList | Remove-HnsPolicyList -ErrorAction SilentlyContinue
}

if ($shallRestartDocker) {
    Start-ServiceProcess 'docker'
}

# Sometimes only removal from registry helps and reboot
if(!$CacheK2sVSwitches) { 
    Write-Log 'Cleaning up registry for NicList'
    Get-ChildItem -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\VMSMP\Parameters\NicList' | Remove-Item -ErrorAction SilentlyContinue | Out-Null
}

# Remove routes
Write-Log "Remove route to $global:IP_CIDR"
route delete $global:IP_CIDR >$null 2>&1
Write-Log "Remove route to $global:ClusterCIDR_Master"
route delete $global:ClusterCIDR_Master >$null 2>&1
Write-Log "Remove route to $global:ClusterCIDR_Host"
route delete $global:ClusterCIDR_Host >$null 2>&1
Write-Log "Remove route to $global:ClusterCIDR_Services"
route delete $global:ClusterCIDR_Services >$null 2>&1
route delete $global:ClusterCIDR_ServicesLinux >$null 2>&1
route delete $global:ClusterCIDR_ServicesWindows >$null 2>&1

Invoke-Hook -HookName 'AfterStopK8sNetwork' -AdditionalHooksDir $AdditionalHooksDir

# Renew with DHCP the ip addresses, in that way NICs get new IP and routes are updated
# Sometimes this does not happen in windows
if ($ipaddressesFromDhcp) {
    Write-Log 'DHCP is used, renew IP address (ipconfig /renew)'
    ipconfig /renew >$null 2>&1
}
else {
    Write-Log 'No DHCP active, so no renewing of IP address'
}

Write-Log "Disabling network adapter $global:LoopbackAdapter"
Disable-NetAdapter -Name $global:LoopbackAdapter -Confirm:$false -ErrorAction SilentlyContinue

Write-Log '...Kubernetes system stopped.'

