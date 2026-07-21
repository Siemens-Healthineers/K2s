# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Provisions a raw, unformatted, unpartitioned disk for a Ceph OSD on a Debian node and prepares it.

.DESCRIPTION
Determines whether the target OSD node identified by -NodeIp is a local Hyper-V virtual machine or
a bare-metal machine, reusing the same detection K2s uses when adding worker nodes: prefer the
KubeSwitch ARP/MAC-to-VM lookup used by the existing-vm add-node path, and fall back to a direct
Hyper-V adapter IP-address match only when needed. Otherwise the node is treated as bare-metal.

Based on the detected node type it dispatches to the matching shell script:
  - Hyper-V   : creates a new dynamic .vhdx on the Windows host, hot-attaches it to the VM as a raw
                SCSI disk, discovers the resulting guest device, then runs
                osd\hyperv\prepare-osd-disk-hyperv.sh to wipe it to a raw state.
  - Bare-metal: runs osd\baremetal\prepare-osd-disk-baremetal.sh against an EXISTING empty physical
                disk that must be provided explicitly (a physical disk cannot be created).

.PARAMETER NodeIp
IP address of the OSD node (ceph-config.json 'clusterHostNodeIp').

.PARAMETER UserName
SSH user for the OSD node. If omitted it is resolved from the cluster descriptor, falling back to 'remote'.

.PARAMETER Device
Target whole-disk block device on the node, e.g. '/dev/sdb'. REQUIRED for bare-metal nodes.
For Hyper-V nodes it is optional: the freshly-attached virtual disk is discovered automatically.

.PARAMETER DiskSizeGB
Size (in GiB) of the virtual disk to create for a Hyper-V node. Ignored for bare-metal. Default 20.

.PARAMETER Config
The parsed ceph-config.json object (used to resolve the SSH user).

.PARAMETER ShowLogs
If log output shall be streamed also to CLI output.
#>
Param(
    [parameter(Mandatory = $true, HelpMessage = 'IP address of the OSD node')]
    [string] $NodeIp,
    [parameter(Mandatory = $false, HelpMessage = 'SSH user name for the OSD node')]
    [string] $UserName = '',
    [parameter(Mandatory = $false, HelpMessage = 'Target whole-disk device (required for bare-metal)')]
    [string] $Device = '',
    [parameter(Mandatory = $false, HelpMessage = 'Virtual disk size in GiB for Hyper-V nodes')]
    [uint32] $DiskSizeGB = 20,
    [parameter(Mandatory = $false, HelpMessage = 'Force creation of a new Hyper-V virtual disk even when K2s OSD disks already exist')]
    [switch] $CreateNewDisk = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Parsed ceph-config.json object')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)

$infraModule = "$PSScriptRoot/../../../../../../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../../../../../../lib/modules/k2s/k2s.node.module/k2s.node.module.psm1"
$clusterConfigModule = "$PSScriptRoot/../../../../../../../lib/modules/k2s/k2s.infra.module/config/cluster.config.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterConfigModule
Initialize-Logging -ShowLogs:$ShowLogs

$ErrorActionPreference = 'Stop'

# Resolve the SSH user: explicit parameter wins, then the OSD/cluster node descriptor, then a safe default.
$sshUserName = $UserName
if ([string]::IsNullOrWhiteSpace($sshUserName) -and $null -ne $Config) {
    try {
        $nodeName = if (-not [string]::IsNullOrWhiteSpace("$($Config.osdHostNode)".Trim())) {
            "$($Config.osdHostNode)".Trim()
        }
        else {
            "$($Config.clusterHostNode)".Trim()
        }

        $nodeConfig = $null
        if (-not [string]::IsNullOrWhiteSpace($nodeName)) {
            $nodeConfig = Get-NodeConfig -NodeName $nodeName
        }

        if ($null -ne $nodeConfig -and -not [string]::IsNullOrWhiteSpace($nodeConfig.Username)) {
            $sshUserName = $nodeConfig.Username
        }
    }
    catch {
        Write-Log "[Ceph] Could not resolve SSH user from cluster descriptor: $($_.Exception.Message)"
    }
}
if ([string]::IsNullOrWhiteSpace($sshUserName)) {
    $sshUserName = 'remote'
}

function Get-GuestWholeDiskNames {
    param(
        [string] $UserName,
        [string] $IpAddress
    )

    # -e 7,11 excludes loop (major 7) and sr/cdrom (major 11) devices.
    $result = Invoke-CmdOnVmViaSSHKey -CmdToExecute 'lsblk -dn -o NAME -e 7,11' -UserName $UserName -IpAddress $IpAddress -NoLog -IgnoreErrors -Retries 3
    $names = @(($result.Output | Out-String) -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    return , $names
}

function Resolve-HyperVVmNameByIp {
    param(
        [Parameter(Mandatory = $true)][string] $IpAddress
    )

    try {
        $kubeSwitchName = Get-ControlPlaneNodeDefaultSwitchName
        if (-not [string]::IsNullOrWhiteSpace($kubeSwitchName)) {
            Test-Connection -ComputerName $IpAddress -Count 2 -Quiet -ErrorAction SilentlyContinue | Out-Null

            $arpEntry = Get-NetNeighbor -IPAddress $IpAddress -ErrorAction SilentlyContinue | Where-Object { $_.State -ne 'Unreachable' } | Select-Object -First 1
            if ($null -ne $arpEntry -and -not [string]::IsNullOrWhiteSpace($arpEntry.LinkLayerAddress)) {
                $targetMac = $arpEntry.LinkLayerAddress -replace '-', ''
                $vmsOnKubeSwitch = @(Get-VM | Where-Object {
                    $adapters = Get-VMNetworkAdapter -VMName $_.Name -ErrorAction SilentlyContinue
                    @($adapters | Where-Object { $_.SwitchName -eq $kubeSwitchName }).Count -gt 0
                })

                foreach ($vm in $vmsOnKubeSwitch) {
                    $adapters = @(Get-VMNetworkAdapter -VMName $vm.Name -ErrorAction SilentlyContinue)
                    foreach ($adapter in $adapters) {
                        $vmMac = $adapter.MacAddress -replace '-', ''
                        if ($vmMac -eq $targetMac) {
                            Write-Log "[Ceph] Matched node '$IpAddress' to Hyper-V VM '$($vm.Name)' via ARP/MAC lookup on switch '$kubeSwitchName'."
                            return $vm.Name
                        }
                    }
                }
            }
        }
    }
    catch {
        Write-Log "[Ceph] Hyper-V ARP/MAC detection failed for '$IpAddress': $($_.Exception.Message)"
    }

    try {
        $vmAdapter = Get-VMNetworkAdapter -All -ErrorAction SilentlyContinue | Where-Object { @($_.IPAddresses) -contains $IpAddress } | Select-Object -First 1
        if ($null -ne $vmAdapter -and -not [string]::IsNullOrWhiteSpace($vmAdapter.VMName)) {
            Write-Log "[Ceph] Matched node '$IpAddress' to Hyper-V VM '$($vmAdapter.VMName)' via direct guest-IP adapter lookup."
            return $vmAdapter.VMName
        }
    }
    catch {
        Write-Log "[Ceph] Hyper-V guest-IP detection failed for '$IpAddress': $($_.Exception.Message)"
    }

    return $null
}

# ---------------------------------------------------------------------------
# Determine node type using the same signal K2s uses when adding a worker node:
# prefer KubeSwitch ARP/MAC lookup to identify an existing Hyper-V VM.
# ---------------------------------------------------------------------------
$vmName = Resolve-HyperVVmNameByIp -IpAddress $NodeIp

if (-not [string]::IsNullOrWhiteSpace($vmName)) {
    $nodeType = 'HyperV'
    Write-Log "[Ceph] Node '$NodeIp' detected as a local Hyper-V VM ('$vmName')." -Console
}
else {
    $nodeType = 'BareMetal'
    $loopbackAdapter = Get-L2BridgeName
    if (Test-IpInPhysicalSubnet -IpAddress $NodeIp -ExcludeNetworkInterfaceName $loopbackAdapter) {
        Write-Log "[Ceph] Node '$NodeIp' detected as a bare-metal machine (IP belongs to a physical host subnet)." -Console
    }
    else {
        Write-Log "[Ceph] Node '$NodeIp' was not matched to a local Hyper-V VM; treating it as bare-metal." -Console
    }
}

# ---------------------------------------------------------------------------
# Provision / prepare the OSD disk according to the node type.
# ---------------------------------------------------------------------------
if ($nodeType -eq 'HyperV') {
    $diskScript = Join-Path $PSScriptRoot 'hyperv\prepare-osd-disk-hyperv.sh'

    # If no explicit device was given, create and attach a fresh virtual disk, then discover it.
    if ([string]::IsNullOrWhiteSpace($Device)) {
        $vmHardDisks = @(Get-VMHardDiskDrive -VMName $vmName -ErrorAction SilentlyContinue)
        $existingK2sOsdDisks = @($vmHardDisks | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.Path) -and ((Split-Path $_.Path -Leaf) -like 'ceph-osd-*.vhdx')
        })

        if ($existingK2sOsdDisks.Count -gt 0 -and -not $CreateNewDisk) {
            $existingPaths = @($existingK2sOsdDisks | ForEach-Object { $_.Path }) -join ', '
            Write-Log "[Ceph] Reusing existing K2s OSD virtual disk attachment(s) on VM '$vmName': $existingPaths" -Console
            Write-Log "[Ceph] Skipping creation of a new virtual disk to avoid accumulating extra OSD volumes across retries." -Console
        }
        else {
            if ($existingK2sOsdDisks.Count -gt 0 -and $CreateNewDisk) {
                Write-Log "[Ceph] Existing K2s OSD disk(s) already attached on VM '$vmName'; creating an additional OSD disk as requested." -Console
            }
            Write-Log "[Ceph] Creating and attaching a new ${DiskSizeGB} GiB virtual disk to VM '$vmName'..." -Console

            $disksBefore = Get-GuestWholeDiskNames -UserName $sshUserName -IpAddress $NodeIp

            # Place the new VHDX next to the VM's existing disk (or the VM folder as a fallback).
            $osDisk = $vmHardDisks | Select-Object -First 1
            if ($null -ne $osDisk -and -not [string]::IsNullOrWhiteSpace($osDisk.Path)) {
                $vhdxDir = Split-Path $osDisk.Path -Parent
            }
            else {
                $vhdxDir = (Get-VM -Name $vmName).Path
            }
            $vhdxPath = Join-Path $vhdxDir ("ceph-osd-" + ([guid]::NewGuid().ToString('N').Substring(0, 8)) + '.vhdx')

            $vhdxCreated = $false
            try {
                New-VHD -Path $vhdxPath -SizeBytes ([int64]$DiskSizeGB * 1GB) -Dynamic | Out-Null
                $vhdxCreated = $true
                Add-VMHardDiskDrive -VMName $vmName -Path $vhdxPath -ControllerType SCSI
                Write-Log "[Ceph] Attached virtual disk '$vhdxPath' to VM '$vmName'."
            }
            catch {
                Write-Log "[Ceph] ERROR: Failed to create/attach the virtual disk: $($_.Exception.Message)" -Console -Error
                if ($vhdxCreated -and (Test-Path $vhdxPath)) {
                    Remove-Item -Path $vhdxPath -Force -ErrorAction SilentlyContinue
                }
                exit 1
            }

            # Trigger a SCSI rescan inside the guest and let udev settle so the new disk appears.
            Invoke-CmdOnVmViaSSHKey -CmdToExecute 'for h in /sys/class/scsi_host/host*/scan; do echo "- - -" | sudo tee $h > /dev/null; done; sudo udevadm settle' -UserName $sshUserName -IpAddress $NodeIp -NoLog -IgnoreErrors -Retries 3 | Out-Null
            Start-Sleep -Seconds 3

            $disksAfter = Get-GuestWholeDiskNames -UserName $sshUserName -IpAddress $NodeIp
            $newDisks = @($disksAfter | Where-Object { $disksBefore -notcontains $_ })

            if ($newDisks.Count -eq 1) {
                $Device = "/dev/$($newDisks[0])"
                Write-Log "[Ceph] New virtual disk appeared in guest as '$Device'."
            }
            elseif ($newDisks.Count -eq 0) {
                Write-Log "[Ceph] Attached the virtual disk but the guest did not expose a new device; letting the script auto-detect it." -Console
            }
            else {
                Write-Log "[Ceph] Multiple new devices appeared in the guest ($($newDisks -join ', ')); letting the script auto-detect the empty one." -Console
                $Device = ''
            }
        }
    }

    $scriptArgs = if ([string]::IsNullOrWhiteSpace($Device)) { @() } else { @($Device) }
}
else {
    $diskScript = Join-Path $PSScriptRoot 'baremetal\prepare-osd-disk-baremetal.sh'

    if ([string]::IsNullOrWhiteSpace($Device)) {
        Write-Log "[Ceph] ERROR: A bare-metal OSD node requires an explicit target disk. Pass -Device (e.g. /dev/sdb)." -Console -Error
        exit 1
    }
    $scriptArgs = @($Device)
}

if (-not (Test-Path $diskScript)) {
    Write-Log "[Ceph] ERROR: OSD disk preparation script not found: '$diskScript'" -Console -Error
    exit 1
}

Write-Log "[Ceph] Preparing raw OSD disk on '$NodeIp' ($nodeType)$(if ($Device) { " target '$Device'" })..." -Console
$diskOutput = Invoke-RemoteScript -LocalScriptPath $diskScript -UserName $sshUserName -IpAddress $NodeIp -Arguments $scriptArgs -CleanupAfterExecution -Retries 2

$diskOutputText = ($diskOutput | Out-String)
$readyLine = $diskOutputText -split "`r?`n" | Where-Object { $_.Trim().StartsWith('K2S_CEPH_OSD_DISK_READY=') } | Select-Object -Last 1
$diskLine = $diskOutputText -split "`r?`n" | Where-Object { $_.Trim().StartsWith('K2S_CEPH_OSD_DISK=') } | Select-Object -Last 1

if ([string]::IsNullOrWhiteSpace($readyLine)) {
    Write-Log "[Ceph] ERROR: OSD disk preparation did not complete successfully on node '$NodeIp'." -Console -Error
    exit 1
}

$preparedDisk = if (-not [string]::IsNullOrWhiteSpace($diskLine)) { $diskLine.Trim().Substring('K2S_CEPH_OSD_DISK='.Length).Trim() } else { $Device }
Write-Log "[Ceph] Raw OSD disk '$preparedDisk' is ready on node '$NodeIp' - cephadm/ceph-volume can now consume it as an OSD." -Console
Write-Output "K2S_CEPH_OSD_DISK=$preparedDisk"
Write-Output "K2S_CEPH_OSD_NODE_IP=$NodeIp"
exit 0
