# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

$infraModule = "$PSScriptRoot\..\..\..\k2s.infra.module\k2s.infra.module.psm1"
$loopBackAdapterModule = "$PSScriptRoot\..\network\loopbackadapter.module.psm1"
Import-Module $infraModule, $loopBackAdapterModule

$kubeBinPath = Get-KubeBinPath

function Get-IsNssmServiceRunning($name) {
    return $(Get-Service -Name $name -ErrorAction SilentlyContinue).Status -eq "Running"
}

function Start-NssmService($name) {
    $svc = $(Get-Service -Name $name -ErrorAction SilentlyContinue).Status
    if (($svc) -and ($svc -ne 'Running')) {
        Write-Log ('Starting service: ' + $name)
        &$kubeBinPath\nssm start $name
    }
}

function Restart-NssmService($name) {
    $svc = $(Get-Service -Name $name -ErrorAction SilentlyContinue).Status
    if (($svc) -and ($svc -eq 'Running')) {
        Write-Log ('Restarting service: ' + $name)
        &$kubeBinPath\nssm restart $name
    }
}

function Stop-NssmService($name) {
    $svc = $(Get-Service -Name $name -ErrorAction SilentlyContinue).Status
    if (($svc) -and ($svc -ne 'Stopped')) {
        Write-Log ('Stopping service: ' + $name)
        &$kubeBinPath\nssm stop $name
    }
}

function Start-ServiceProcess($serviceName) {
    $svc = $(Get-Service -Name $serviceName -ErrorAction SilentlyContinue).Status
    if (($svc) -and ($svc -ne 'Running')) {
        Write-Log ('Starting service: ' + $serviceName)
        Start-Service -Name $serviceName -WarningAction SilentlyContinue
    }
}

function Stop-ServiceProcess($serviceName, $processName) {
    if ($(Get-Service -Name $serviceName -ErrorAction SilentlyContinue).Status -eq 'Running') {
        Write-Log ("Stopping running service: " + $serviceName)
        Stop-Service -Name $serviceName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    }
    Stop-Process -Name $processName -Force -ErrorAction SilentlyContinue
}

<#
.SYNOPSIS
    Outputs node service status.
.DESCRIPTION
    Outputs node service status.
.PARAMETER Iteration
    Iteration no.
.EXAMPLE
    Write-NodeServiceStatus -Iteration 3
#>
function Write-NodeServiceStatus {
    param (
        [Parameter(Mandatory = $true)]
        [int] $Iteration
    )

    $prefix = "State of services (checkpoint $Iteration):"
    $stateFlanneld = $(Get-Service flanneld).Status
    $stateKubelet = $(Get-Service kubelet).Status
    $stateKubeproxy = $(Get-Service kubeproxy).Status
    if ($stateFlanneld -eq 'Running' -and $stateKubelet -eq 'Running' -and $stateKubeproxy -eq 'Running') {
        Write-Log "$prefix All running"
    }
    elseif ($stateFlanneld -eq 'Stopped' -and $stateKubelet -eq 'Stopped' -and $stateKubeproxy -eq 'Stopped') {
        Write-Log "$prefix All STOPPED"
    }
    else {
        Write-Log "$prefix"
        Write-Log "             flanneld:  $stateFlanneld"
        Write-Log "             kubelet:   $stateKubelet"
        Write-Log "             kubeproxy: $stateKubeproxy"
    }

    Write-Log '###################################################'
    Write-Log "flanneld:  $stateFlanneld"
    $adapterName = Get-L2BridgeName
    Get-NetIPAddress -InterfaceAlias $adapterName -ErrorAction SilentlyContinue | Out-Null
}

<#
.SYNOPSIS
    Restarts a specified service if it is running
.DESCRIPTION
    Restarts a specified service if it is running.
.PARAMETER Name
    Name of the service
.EXAMPLE
    Restart-WinService -Name 'WslService'
.NOTES
    Does nothing if the service was not found.
#>
function Restart-WinService {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Name = $(throw 'Please provide the name of the windows service.')
    )

    $svc = $(Get-Service -Name $Name -ErrorAction SilentlyContinue).Status
    if ($svc) {
        Write-Log "Service status before restarting '$Name': $svc"
        Restart-Service $Name -WarningAction SilentlyContinue -Force
        $iteration = 0
        while ($true) {
            $iteration++
            $svcstatus = $(Get-Service -Name $Name -ErrorAction SilentlyContinue).Status
            if ($svcstatus -eq 'Running') {
                Write-Log "Service re-started '$Name' "
                break
            }
            if ($iteration -ge 5) {
                Write-Warning "'$Name' Service is not running !!"
                break
            }
            Write-Log "'$Name' Waiting for service status to be started: $svc"
            Start-Sleep -s 2
        }
        return
    }
    Write-Warning "Service not found: $Name"
}

function Start-WSL() {
    Restart-WinService 'WslService'
    Write-Log 'Disable Remote App authentication warning dialog'
    REG ADD 'HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' /V 'AuthenticationLevel' /T REG_DWORD /D '0' /F

    Write-Log 'Start KubeMaster with WSL2'
    Start-Process wsl -WindowStyle Hidden
}

Export-ModuleMember -Function Start-NssmService,
Restart-NssmService, Stop-NssmService,
Get-IsNssmServiceRunning, Write-NodeServiceStatus,
Restart-WinService, Start-ServiceProcess, Stop-ServiceProcess, Start-WSL