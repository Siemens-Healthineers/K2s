# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Uninstalls KubeVirt in the cluster

.DESCRIPTION
Kubevirt is needed for running VMs in Kubernetes for apps which cannot containerized

#>

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'K8sSetup: SmallSetup')]
    [string] $K8sSetup = 'SmallSetup'
)

$mainStopwatch = [system.diagnostics.stopwatch]::StartNew()

# load global settings
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1

. $PSScriptRoot\Common.ps1

Import-Module "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
Initialize-Logging -ShowLogs:$ShowLogs

$addonsModule = "$PSScriptRoot\..\Addons.module.psm1"

Import-Module $addonsModule


Write-Log 'Checking cluster status' -Console
Test-ClusterAvailability

Write-Log "Check whether kubevirt addon is already disabled"
if ($null -eq (&$global:KubectlExe get namespace kubevirt --ignore-not-found)) {
    Write-Log 'Addon already disabled.' -Console
    exit 0
}

Write-Log 'Uninstalling kubevirt addon' -Console

# show all pods
Write-Log "`nKubernetes pods before:`n"
&$global:KubectlExe get pods -A -o wide | Write-Log

$ScriptBlockNamespaces = {
    param (
        [parameter(Mandatory = $true)]
        [string] $Namespace
    )
    Write-Log "Start to cleanup namespace $Namespace"
    Remove-Item -Path $Namespace-namespace.json -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $Namespace-namespace-cleaned.json -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 60
    $n = &$global:KubectlExe get namespace $Namespace
    if ($n) {
        &$global:KubectlExe get namespace $Namespace -o json > $Namespace-namespace.json
        $json = Get-Content $Namespace-namespace.json -Encoding Ascii | ConvertFrom-Json
        if ( $json ) {
            Write-Log ($json.spec.finalizers | Format-List | Out-String)
            $json.spec.finalizers = @()
            $json | ConvertTo-Json -depth 100 | Out-File $Namespace-namespace-cleaned.json -Encoding Ascii
            &$global:KubectlExe replace --raw "/api/v1/namespaces/$Namespace/finalize" -f $Namespace-namespace-cleaned.json | Write-Log
        }
    }
    Write-Log "Namespace $Namespace clean now !"
}

# delete kubevirt
&$global:KubectlExe delete -n kubevirt kubevirt kubevirt --wait=true >$null 2>&1 | Write-Log
&$global:KubectlExe delete apiservices v1alpha3.subresources.kubevirt.io >$null 2>&1 | Write-Log
&$global:KubectlExe delete mutatingwebhookconfigurations virt-api-mutator >$null 2>&1 | Write-Log
&$global:KubectlExe delete validatingwebhookconfigurations virt-api-validator >$null 2>&1 | Write-Log
&$global:KubectlExe delete validatingwebhookconfigurations virt-operator-validator >$null 2>&1 | Write-Log
&$global:KubectlExe delete -f "$global:KubernetesPath\addons\kubevirt\kubevirt-operator.yaml" --wait=false >$null 2>&1 | Write-Log

# delete kubevirt
Write-Log "delete kubevirt"
if ($PSVersionTable.PSVersion.Major -gt 5) {
    &$global:KubectlExe patch namespace kubevirt -p '{"metadata":{"finalizers":null}}' >$null 2>&1 | Write-Log
} else {
    &$global:KubectlExe patch namespace kubevirt -p '{\"metadata\":{\"finalizers\":null}}' >$null 2>&1 | Write-Log
}

Start-Job $ScriptBlockNamespaces -ArgumentList 'kubevirt'

# delete entire namespace
&$global:KubectlExe delete namespace kubevirt --force --grace-period=0 >$null 2>&1 | Write-Log
Write-Log "Total duration: $('{0:hh\:mm\:ss}' -f $mainStopwatch.Elapsed )"

# show all pods
Write-Log "`nKubernetes pods after:`n"
&$global:KubectlExe get pods -A -o wide | Write-Log

# remove runtime settings
# only for Small K8s Setup we use software virtualization
if ( $K8sSetup -eq 'SmallSetup' ) {
    # remove cgroup setting
    Write-Log "change back to cgroup v2"
    ExecCmdMaster "sudo sed -i 's,systemd.unified_cgroup_hierarchy=0\ ,,g' /etc/default/grub"
    ExecCmdMaster 'sudo update-grub 2>&1'

    # restart KubeMaster
    Write-Log "Stopping VM $global:VMName"
    Stop-VM -Name $global:VMName -Force -WarningAction SilentlyContinue
    $state = (Get-VM -Name $global:VMName).State -eq [Microsoft.HyperV.PowerShell.VMState]::Off
    while (!$state) {
        Write-Log "Still waiting for stop..."
        Start-Sleep -s 1
    }
     Write-Log "Start VM $global:VMName"
    Start-VM -Name $global:VMName
    Wait-ForSSHConnectionToLinuxVMViaSshKey
}

Remove-AddonFromSetupJson -Name 'kubevirt'

Remove-Item "$global:KubernetesPath\bin\virtctl.exe" -Force -ErrorAction SilentlyContinue

Write-Log "Remove virtviewer" -Console
$virtviewer = 'virt-viewer-x64-11.0-1.0.msi';
msiexec /x "$global:KubernetesPath\bin\$virtviewer" /qn /L*VX "$global:KubernetesPath\bin\msiuninstall.log"
Remove-Item "$global:KubernetesPath\bin\$virtviewer" -Force -ErrorAction SilentlyContinue

Write-Log 'Uninstallation of kubevirt addon is now done'


