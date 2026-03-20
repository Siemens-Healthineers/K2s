# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

function Start-NodePackageVmProvisioning {
	param (
		[Parameter(Mandatory = $true)]
		[string] $DistributionKey,
		[Parameter(Mandatory = $true)]
		[string] $VmName,
		[Parameter(Mandatory = $false)]
		[string] $Proxy = '',
		[Parameter(Mandatory = $false)]
		[switch] $ShowLogs
	)

	# Hardcoded defaults
	$sshUser = 'admin'
	$sshPwd = 'admin'
	$netIntf = 'eth0'

	$kubePath = Get-KubePath
	$kubeBinPath = Get-KubeBinPath

	$suffix = [guid]::NewGuid().ToString('N').Substring(0, 6)
	$switchName = "k2s-node-$DistributionKey-$suffix"
	$natName = "k2s-node-$DistributionKey-$suffix"

	# Pick a free subnet from 192.168.100-200
	$usedSubnets = @(
		(Get-NetNat -ErrorAction SilentlyContinue | ForEach-Object { if ($_.InternalIPInterfaceAddressPrefix -match '192\.168\.(\d+)\.') { [int]$matches[1] } })
		(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { if ($_.IPAddress -match '192\.168\.(\d+)\.') { [int]$matches[1] } })
	) | Select-Object -Unique
	$randomSubnet = 100..200 | Where-Object { $_ -notin $usedSubnets } | Get-Random
	if (-not $randomSubnet) {
		throw '[NodePkg] No free 192.168.x.0/24 subnet available in range 100-200. Clean up stale NATs manually.'
	}
	Write-Log "[NodePkg] Selected free subnet: 192.168.$randomSubnet.0/24" -Console

	$hostIp = "192.168.$randomSubnet.1"
	$guestIp = "192.168.$randomSubnet.10"
	$prefixLen = 24
	$natIp = "192.168.$randomSubnet.0"
	$hostDns = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
		ForEach-Object { @($_.ServerAddresses) } |
		Where-Object { $_ -and $_ -ne '0.0.0.0' -and $_ -notlike '127.*' } |
		Select-Object -First 1
	if ([string]::IsNullOrWhiteSpace($hostDns)) {
		$hostDns = '8.8.8.8'
		Write-Log "[NodePkg] No host DNS detected. Falling back to '$hostDns'." -Console
	}
	else {
		Write-Log "[NodePkg] Using host DNS '$hostDns' for VM provisioning." -Console
	}

	$tempPath = [System.IO.Path]::GetTempPath()
	$workingRoot = Join-Path $tempPath "k2s-node-pkg-$([guid]::NewGuid().ToString().Substring(0, 8))"
	$downloadsDir = Join-Path $workingRoot 'downloads'
	$provisioningDir = Join-Path $workingRoot 'provisioning'
	New-Item -Path $downloadsDir -ItemType Directory -Force | Out-Null
	New-Item -Path $provisioningDir -ItemType Directory -Force | Out-Null

	$vhdxName = "$VmName.vhdx"
	$isoName = "$VmName.iso"

	$vmParams = @{
		VmName               = $VmName
		VhdxName             = $vhdxName
		VMMemoryStartupBytes = 2GB
		VMProcessorCount     = 2
		VMDiskSize           = 20GB
	}
	$netParams = @{
		Proxy              = $Proxy
		SwitchName         = $switchName
		HostIpAddress      = $hostIp
		HostIpPrefixLength = $prefixLen
		NatName            = $natName
		NatIpAddress       = $natIp
		DnsIpAddresses     = $hostDns
	}
	$isoParams = @{
		IsoFileCreatorToolPath = Join-Path $kubeBinPath 'cloudinitisobuilder.exe'
		IsoFileName            = $isoName
		SourcePath             = Join-Path $kubePath 'lib\modules\k2s\k2s.node.module\linuxnode\baseimage\cloud-init-templates'
		Hostname               = "k2s-nodepkg-$DistributionKey"
		NetworkInterfaceName   = $netIntf
		IPAddressVM            = $guestIp
		IPAddressGateway       = $hostIp
		UserName               = $sshUser
		UserPwd                = $sshPwd
	}
	$dirParams = @{
		DownloadsDirectory    = $downloadsDir
		ProvisioningDirectory = $provisioningDir
	}

	# Phase 1
	Write-Log "[NodePkg] === Phase 1: Creating Hyper-V VM for '$DistributionKey' ===" -Console
	New-LinuxCloudBasedVirtualMachine `
		-VirtualMachineParams $vmParams `
		-NetworkParams $netParams `
		-IsoFileParams $isoParams `
		-WorkingDirectoriesParams $dirParams `
		-TargetDistribution $DistributionKey

	# Phase 2
	Write-Log "[NodePkg] === Phase 2: Starting VM '$VmName' ===" -Console
	Start-VirtualMachineAndWaitForHeartbeat -Name $VmName

	# Phase 3
	Write-Log "[NodePkg] === Phase 3: Waiting for SSH ($sshUser@$guestIp) ===" -Console
	Wait-ForSshPossible `
		-User "$sshUser@$guestIp" `
		-UserPwd $sshPwd `
		-SshTestCommand 'which ls' `
		-ExpectedSshTestCommandResult '/usr/bin/ls'

	return [PSCustomObject]@{
		VmName                 = $VmName
		SwitchName             = $switchName
		NatName                = $natName
		GuestIp                = $guestIp
		SshUser                = $sshUser
		SshPwd                 = $sshPwd
		InProvisioningVhdxPath = (Join-Path $provisioningDir $vhdxName)
	}
}

