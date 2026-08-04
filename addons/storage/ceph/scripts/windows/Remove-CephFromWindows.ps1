# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Removes the Ceph native Windows setup from the Windows worker node(s) of a K2s cluster.

.DESCRIPTION
Invoked by the storage/ceph addon Disable.ps1. Unmounts CephFS (stops/unregisters the startup task
and terminates ceph-dokan) and removes the Ceph client configuration (ceph.conf and keyring) written
on the local HOST Windows worker node during enable. Ceph on Windows uses only the native host client
(no containerized CSI node plugin / DaemonSet), so there are no Kubernetes manifests to delete. The
native Ceph for Windows client (WNBD driver, ceph-dokan) and Dokany are intentionally NOT uninstalled
here: they are shared Windows components and uninstalling the WNBD driver requires a reboot. Pass
-RemoveClient to also uninstall them.

.PARAMETER RemoveClient
If set, also uninstalls the native Ceph for Windows client and Dokany from the local HOST node. A
reboot may be required afterwards.

.PARAMETER ShowLogs
If log output shall be streamed also to CLI output.
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Also uninstall the native Ceph client and Dokany')]
    [switch] $RemoveClient = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)

$infraModule = "$PSScriptRoot/../../../../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
Import-Module $infraModule, $clusterModule
Initialize-Logging -ShowLogs:$ShowLogs

$cephProgramData = "$env:ProgramData\ceph"
$mountScript = "$PSScriptRoot\Mount-CephForWindows.ps1"

# Unmount CephFS and remove the startup task first, so no ceph-dokan process is holding the mount or
# the configuration files open when we remove them.
if (Test-Path -Path $mountScript) {
    Write-Log '[CephWin] Unmounting CephFS and removing the startup task' -Console
    & $mountScript -Unmount -ShowLogs:$ShowLogs
    if ($LASTEXITCODE -ne 0) {
        Write-Log "[CephWin] WARNING: CephFS unmount reported a problem (exit code $LASTEXITCODE); continuing with cleanup." -Console
    }
}

# Remove the Ceph client configuration written on the local Windows host.
if (Test-Path -Path $cephProgramData) {
    Write-Log "[CephWin] Removing Ceph client configuration from $cephProgramData" -Console
    Remove-Item -Path "$cephProgramData\ceph.conf" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$cephProgramData\keyring" -Force -ErrorAction SilentlyContinue
}

if ($RemoveClient) {
    Write-Log '[CephWin] Uninstalling the native Ceph for Windows client (a reboot may be required for the WNBD driver).' -Console

    # Uninstall Ceph for Windows and Dokany via their registered uninstall entries.
    $targets = @('Ceph', 'Dokan')
    foreach ($target in $targets) {
        $product = Get-CimInstance -ClassName Win32_Product -ErrorAction SilentlyContinue |
            Where-Object { "$($_.Name)" -like "*$target*" } | Select-Object -First 1
        if ($null -ne $product) {
            Write-Log "[CephWin] Uninstalling '$($product.Name)'" -Console
            $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/x', "$($product.IdentifyingNumber)", '/qn', '/norestart') -Wait -PassThru -NoNewWindow
            if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
                Write-Log "[CephWin] WARNING: Uninstall of '$($product.Name)' returned exit code $($process.ExitCode)." -Console
            }
        }
    }
}

Write-Log '[CephWin] Windows Ceph native setup removal completed.' -Console
exit 0
