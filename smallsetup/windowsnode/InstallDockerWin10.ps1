# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

# set-executionpolicy remotesigned

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Start docker daemon and keep running')]
    [switch] $AutoStart = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Proxy to use')]
    [string] $Proxy = ''
)

# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\..\common\GlobalFunctions.ps1

if ((Get-Service 'docker' -ErrorAction SilentlyContinue)) {
    Write-Log "dockerd service found, please uninstall first"
    throw 'dockerd service found. Please uninstall first in order to continue!'
}

# Install Windows feature 'containers' is already done in InstallK8s, no need to do it here again

if (Get-Service docker -ErrorAction SilentlyContinue) {
    Write-Log "Stop docker service"
    Stop-Service docker
}

if (Test-Path $global:DockerConfigDir) {
    $newName = $global:DockerConfigDir + '_' + $( Get-Date -Format yyyy-MM-dd_HHmmss )
    Write-Log ("Saving: $global:DockerConfigDir to $newName")
    Rename-Item $global:DockerConfigDir -NewName $newName
}

# Register the Docker daemon as a service.
$serviceName = 'docker'
if (!(Get-Service $serviceName -ErrorAction SilentlyContinue)) {
    Write-Log "Register the docker daemon as a service"
    $storageLocalDrive = Get-StorageLocalDrive
    mkdir -force "$storageLocalDrive\docker" | Out-Null

    # &"$global:KubernetesPath\bin\docker\dockerd" --exec-opt isolation=process --data-root "$storageLocalDrive\docker" --register-service
    # &"$global:KubernetesPath\bin\docker\dockerd" --log-level debug  -H fd:// --containerd="\\\\.\\pipe\\containerd-containerd" --register-service

    $target = "$($global:SystemDriveLetter):\var\log\dockerd"
    Remove-Item -Path $target -Force -Recurse -ErrorAction SilentlyContinue | Out-Null
    mkdir "$($global:SystemDriveLetter):\var\log\dockerd" -ErrorAction SilentlyContinue | Out-Null
    &$global:NssmInstallDirectory\nssm install docker $global:KubernetesPath\bin\docker\dockerd.exe
    &$global:NssmInstallDirectory\nssm set docker AppDirectory $global:KubernetesPath\bin\docker | Out-Null
    &$global:NssmInstallDirectory\nssm set docker AppParameters --exec-opt isolation=process --data-root "$storageLocalDrive\docker" --log-level debug | Out-Null
    &$global:NssmInstallDirectory\nssm set docker AppStdout "$($global:SystemDriveLetter):\var\log\dockerd\dockerd_stdout.log" | Out-Null
    &$global:NssmInstallDirectory\nssm set docker AppStderr "$($global:SystemDriveLetter):\var\log\dockerd\dockerd_stderr.log" | Out-Null
    &$global:NssmInstallDirectory\nssm set docker AppStdoutCreationDisposition 4 | Out-Null
    &$global:NssmInstallDirectory\nssm set docker AppStderrCreationDisposition 4 | Out-Null
    &$global:NssmInstallDirectory\nssm set docker AppRotateFiles 1 | Out-Null
    &$global:NssmInstallDirectory\nssm set docker AppRotateOnline 1 | Out-Null
    &$global:NssmInstallDirectory\nssm set docker AppRotateSeconds 0 | Out-Null
    &$global:NssmInstallDirectory\nssm set docker AppRotateBytes 500000 | Out-Null

    if ( $Proxy -ne '' ) {
        Write-Log("Setting proxy for docker: $Proxy")
        $NoProxy = "localhost,$global:IP_Master,10.81.0.0/16,$global:ClusterCIDR,$global:ClusterCIDR_Services,$global:IP_CIDR,.local"
        &$global:NssmInstallDirectory\nssm set docker AppEnvironmentExtra HTTP_PROXY=$Proxy HTTPS_PROXY=$Proxy NO_PROXY=$NoProxy | Out-Null
    }
}

# check nssm
$nssm = Get-Command 'nssm.exe' -ErrorAction SilentlyContinue
if ($AutoStart) {
    if ($nssm) {
        &nssm set $serviceName Start SERVICE_AUTO_START 2>&1 | Out-Null
    }
    else {
        &$global:NssmInstallDirectory\nssm set $serviceName Start SERVICE_AUTO_START 2>&1 | Out-Null
    }
}
else {
    if ($nssm) {
        &nssm set $serviceName Start SERVICE_DEMAND_START 2>&1 | Out-Null
    }
    else {
        &$global:NssmInstallDirectory\nssm set $serviceName Start SERVICE_DEMAND_START 2>&1 | Out-Null
    }
}

# Start the Docker service, if wanted
if ($AutoStart) {
    Write-Log "Starting '$serviceName' service"
    Start-Service $serviceName -WarningAction SilentlyContinue
}

# update metric for NAT interface
$ipindex2 = Get-NetIPInterface | ? InterfaceAlias -Like '*nat*' | select -expand 'ifIndex'
if ($ipindex2 -ne $null) {
    Set-NetIPInterface -InterfaceIndex $ipindex2 -InterfaceMetric 6000
}

Write-Log "Script finished"