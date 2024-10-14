# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator
# set-executionpolicy remotesigned

# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1

function Stop-ServiceProcess($serviceName, $processName) {
    if ($(Get-Service -Name $serviceName -ErrorAction SilentlyContinue).Status -eq 'Running') {
        Write-Log ("Stopping running service: " + $serviceName)
        Stop-Service -Name $serviceName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    }
    Stop-Process -Name $processName -Force -ErrorAction SilentlyContinue
}

$serviceWasRemoved = $false
if (Test-Path $global:DockerExe) {
    if (Get-Service 'docker' -ErrorAction SilentlyContinue) {
        # only remove docker service if it is not from DockerDesktop
        Stop-ServiceProcess 'docker' 'dockerd'
        Write-Log "Unregistering service: docker (dockerd.exe)"
        &"$global:KubernetesPath\bin\docker\dockerd" --unregister-service
        Start-Sleep 3
        $i = 0
        while (Get-Service 'docker' -ErrorAction SilentlyContinue) {
            $i++
            if ($i -ge 20) {
                Write-Log "trying to forcefully stop dockerd.exe"
                Stop-ServiceProcess 'docker' 'dockerd'
                sc.exe delete 'docker' -ErrorAction SilentlyContinue 2>&1 | Out-Null
            }
            Start-Sleep 1
        }
        $serviceWasRemoved = $true
    }

    if (Test-Path $global:DockerConfigDir) {
        Write-Log "Removing: $global:DockerConfigDir"
        Remove-Item $global:DockerConfigDir -Recurse -Force
    }
}

if ((Get-Service 'docker' -ErrorAction SilentlyContinue) -and !$serviceWasRemoved) {
    # only remove docker service if it is not from DockerDesktop
    Write-Log "Removing service: docker"
    Stop-Service -Force -Name 'docker' | Out-Null
    sc.exe delete 'docker' | Out-Null
}

# remove registry key which could remain from different docker installs
Remove-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\docker' -ErrorAction SilentlyContinue

if ($global:PurgeOnUninstall) {
    Remove-Item -Path "$global:KubernetesPath\smallsetup\docker*.zip" -Force -ErrorAction SilentlyContinue

    Write-Log "Removing: $global:DockerDir"
    Remove-Item $global:DockerDir -Recurse -Force -ErrorAction SilentlyContinue
}
