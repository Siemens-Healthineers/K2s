# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$configModule = "$PSScriptRoot\..\..\k2s.infra.module\config\config.module.psm1"
$logModule = "$PSScriptRoot\..\..\k2s.infra.module\log\log.module.psm1"
$vmModule = "$PSScriptRoot\..\..\k2s.node.module\linuxnode\vm\vm.module.psm1"
$pathModule = "$PSScriptRoot\..\..\k2s.infra.module\path\path.module.psm1"
$vmNodeModule = "$PSScriptRoot\..\..\k2s.node.module\vmnode\vmnode.module.psm1"

Import-Module $configModule, $logModule, $vmModule, $pathModule, $vmNodeModule

$kubeToolsPath = Get-KubeToolsPath

<#
.SYNOPSIS
Performs time synchronization across all nodes of the clusters.
#>
function Invoke-TimeSync {
    param (
        [Parameter(Mandatory = $false)]
        [bool] $WorkerVM
    )

    $timezoneStandardNameOnHost = (Get-TimeZone).StandardName
    $kubeConfigDir = Get-ConfiguredKubeConfigDir
    $windowsTimezoneConfig = "$kubeConfigDir\windowsZones.xml"
    [XML]$timezoneConfigXml = (Get-Content -Path $windowsTimezoneConfig)
    $timezonesLinux = ($timezoneConfigXml.supplementalData.windowsZones.mapTimezones.mapZone | Where-Object { $_.other -eq "$timezoneStandardNameOnHost" }).type
    $canPerformTimeSync = $false
    if ($timezonesLinux.Count -eq 0) {
        Write-Log "No equivalent Linux time zone for Windows time zone $timezoneStandardNameOnHost was found. Cannot perform time synchronization" -Console
        Write-Log 'Please perform time synchronization manually.' -Console
    }
    else {
        $timezoneLinux = $timezonesLinux[0]
        $canPerformTimeSync = $true
    }

    if ($canPerformTimeSync) {
        Write-Log 'Performing time synchronization between nodes'

        #Set timezone in kubemaster
        (Invoke-CmdOnControlPlaneViaSSHKey "sudo timedatectl set-timezone $timezoneLinux 2>&1").Output | Write-Log

        if ($WorkerVM) {
            $session = Open-DefaultWinVMRemoteSessionViaSSHKey
            Invoke-Command -Session $session {
                Set-TimeZone -Name $using:timezoneStandardNameOnHost
            }
        }
    }
}

function Wait-ForAPIServer {
    $controlPlaneVMHostName = Get-ConfigControlPlaneNodeHostname
    $iteration = 0
    while ($true) {
        $iteration++
        # try to apply the flannel resources
        $ErrorActionPreference = 'Continue'
        $result = $(echo yes | &"$kubeToolsPath\kubectl.exe" wait --timeout=60s --for=condition=Ready -n kube-system "pod/kube-apiserver-$($controlPlaneVMHostName.ToLower())" 2>&1)
        $ErrorActionPreference = 'Stop'
        if ($result -match 'condition met') {
            break;
        }
        if ($iteration -eq 10) {
            Write-Log 'API Server could not be started up, aborting...'
            throw 'Unable to get the API Server running !'
        }
        Start-Sleep 2
    }
    if ($iteration -eq 1) {
        Write-Log 'API Server running, no waiting needed'
    }
    else {
        Write-Log 'API Server now running'
    }
}

<#
.SYNOPSIS
    Sets the correct labels and taints for the nodes.
.DESCRIPTION
    Sets the correct labels and taints for the K8s nodes.
.PARAMETER WorkerMachineName
    Optional: Name of the (Windows) worker node
.EXAMPLE
    # consider control-plane-only (i.e. hostname in KubeMaster VM, e.g. kubemaster)
    Update-NodeLabelsAndTaints
.EXAMPLE
    # consider control-plane and (Windows) worker node
    Update-NodeLabelsAndTaints -WorkerMachineName 'my-win-machine'
#>
function Update-NodeLabelsAndTaints {
    param (
        [Parameter(Mandatory = $false)]
        [string] $WorkerMachineName
    )
    Write-Log 'Updating node labels and taints...'
    Write-Log 'Waiting for K8s API server to be ready...'

    Wait-ForAPIServer

    $controlPlaneTaint = 'node-role.kubernetes.io/control-plane'

    # mark control-plane as worker (remove the control-plane tainting)
    (&"$kubeToolsPath\kubectl.exe" get nodes -o=jsonpath='{range .items[*]}~{.metadata.name}#{.spec.taints[*].key}') -split '~' | ForEach-Object {
        $parts = $_ -split '#'

        if ($parts[1] -match $controlPlaneTaint) {
            $node = $parts[0]

            Write-Log "Taint '$controlPlaneTaint' found on node '$node', untainting..."

            &"$kubeToolsPath\kubectl.exe" taint nodes $node "$controlPlaneTaint-"
        }
    }

    if ([string]::IsNullOrEmpty($WorkerMachineName) -eq $false) {
        $nodeName = $WorkerMachineName.ToLower()

        Write-Log "Labeling and tainting worker node '$nodeName'..."

        # mark nodes as worker
        &"$kubeToolsPath\kubectl.exe" label nodes $nodeName kubernetes.io/role=worker --overwrite

        # taint windows nodes
        &"$kubeToolsPath\kubectl.exe" taint nodes $nodeName OS=Windows:NoSchedule --overwrite
    }

    # change default policy in VM (after restart of VM always policy is changed automatically)
    Write-Log 'Reconfiguring volatile settings in VM...'
    (Invoke-CmdOnControlPlaneViaSSHKey 'sudo iptables --policy FORWARD ACCEPT').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey 'sudo sysctl fs.inotify.max_user_instances=8192').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey 'sudo sysctl fs.inotify.max_user_watches=524288').Output | Write-Log
}

Export-ModuleMember Invoke-TimeSync, Wait-ForAPIServer, Update-NodeLabelsAndTaints