# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

<#
.DESCRIPTION
	This module implements delta update functionality for K2s clusters.
	
	EXECUTION CONTEXT DETECTION:
	This module can run in two contexts:
	1. From installed k2s folder (e.g., C:\k\lib\modules\...) - uses relative paths
	2. From extracted delta package - expects modules already loaded by Start-ClusterUpdate.ps1
	
	When running from delta package:
	- Start-ClusterUpdate.ps1 detects delta context and loads modules from target installation
	- This module skips duplicate module loading
	- References target installation via Get-ClusterInstalledFolder for file operations
#>

# Detect if we're running from a delta package (extracted) or from installed k2s
# If delta-manifest.json exists 5 levels up, we're in a delta package
$deltaManifestCheck = Join-Path (Split-Path (Split-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) -Parent) -Parent) 'delta-manifest.json'
$runningFromDelta = Test-Path -LiteralPath $deltaManifestCheck

if ($runningFromDelta) {
	# Running from delta package - modules should already be loaded by Start-ClusterUpdate.ps1
	# No need to import again, but verify key functions are available
	if (-not (Get-Command -Name Write-Log -ErrorAction SilentlyContinue)) {
		Write-Warning "[Update] Running from delta package but Write-Log not available - modules may not be loaded"
	}
	$script:DeferredModuleLoad = $false  # Already loaded by caller
} else {
	# Running from installed k2s - use normal relative paths
	$infraModule = "$PSScriptRoot/../../k2s.infra.module/k2s.infra.module.psm1"
	Import-Module $infraModule
	
	# Import runningstate module for k2s running check
	$runningStateModule = "$PSScriptRoot/../runningstate/runningstate.module.psm1"
	Import-Module $runningStateModule
	$script:DeferredModuleLoad = $false
}

# Helper functions for version validation (from upgrade module)
function Get-ClusterInstalledFolder {
	$installFolder = Get-ConfigInstallFolder
	if ( [string]::IsNullOrEmpty($installFolder) ) {
		# we assume it is the old default
		$installFolder = 'C:\k'
	}
	return $installFolder
}

function Get-ProductVersionGivenKubePath {
	param (
		[Parameter(Mandatory = $false)]
		[string]$KubePathLocal = $(throw 'KubePath not specified')        
	)
	return "$(Get-Content -Raw -Path "$KubePathLocal\VERSION")"
}

function PerformClusterUpdate {
	<#
	.SYNOPSIS
		Applies a delta package to perform an in-place K2s cluster update.
	.DESCRIPTION
		Implements experimental update flow using a previously extracted delta package.
		This function MUST be executed from the extracted delta package directory, NOT from
		the installed k2s directory. The delta package directory is identified by the presence
		of delta-manifest.json in the current working directory.
		
		The update handles running clusters automatically:
		- If cluster is running: Applies Debian packages first, then stops cluster, applies Windows artifacts, restarts cluster
		- If cluster is not running: Skips Debian packages, applies Windows artifacts only
		
		High-level phases:
		  1. Detect delta root (current directory with delta-manifest.json)
		  2. Detect target installation folder (from setup.json/config)
		  3. Load delta-manifest.json (file lists + optional debian-delta metadata)
		  4. Version compatibility validation
		  5. Apply Debian package delta (if cluster is running)
		  6. Stop cluster automatically (if it was running)
		  7. Apply updated Windows artifacts (executables, dlls, scripts) from delta to target installation
		  8. Restart cluster automatically (if it was running before)
		  9. Load / import container images from delta if included
		  10. Run optional hooks (pre/post) [placeholder]
		  11. Basic health checks (API server reachable, node Ready) if cluster is running
		  12. Update VERSION file and setup.json to reflect successful update
	.PARAMETER ExecuteHooks
		Execute lifecycle hooks (currently placeholder; no hooks executed yet).
	.PARAMETER ShowProgress
		Emit coarse progress via Write-Progress at phase boundaries.
	.PARAMETER ShowLogs
		Mirror logs to console.
	.OUTPUTS
		[bool] success indicator.
	.NOTES
		EXPERIMENTAL: logic may evolve; keeps offline guarantees (no network pulls).
		IMPORTANT: Execute this function from the extracted delta package directory.
		The user must:
		  1. Extract the delta package zip: Expand-Archive k2s-delta-xxx.zip -Destination .\delta
		  2. Navigate to the extracted directory: cd .\delta
		  3. Run the update: .\k2s.exe system update
		The cluster will be automatically stopped and restarted if it was running before the update.
	#>
	[CmdletBinding()]
	param(
		[switch] $ExecuteHooks,
		[switch] $ShowProgress,
		[switch] $ShowLogs
	)

	$consoleSwitch = $ShowLogs
	Write-Log '#####################################################################' -Console:$consoleSwitch
	Write-Log '[EXPERIMENTAL] Delta update starting' -Console:$consoleSwitch
	Write-Log '#####################################################################' -Console:$consoleSwitch
	Write-Log ("[Update] Parameters: ExecuteHooks={0} ShowProgress={1} ShowLogs={2}" -f $ExecuteHooks, $ShowProgress, $ShowLogs) -Console:$consoleSwitch

	# Detect delta root - current directory must contain delta-manifest.json
	$deltaRoot = $PWD.Path
	$manifestPath = Join-Path $deltaRoot 'delta-manifest.json'
	
	if (-not (Test-Path -LiteralPath $manifestPath)) {
		$errorMsg = @"
[Update][Error] delta-manifest.json not found in current directory.

This command must be run from the extracted delta package directory.

Usage:
  1. Extract the delta package: Expand-Archive k2s-delta-xxx.zip -Destination .\delta
  2. Navigate to extracted directory: cd .\delta
  3. Run update: .\k2s.exe system update

Current directory: $deltaRoot
"@
		Write-Log $errorMsg -Console
		return $false
	}
	
	Write-Log ("[Update] Delta package root detected: {0}" -f $deltaRoot) -Console:$consoleSwitch

	# Check if k2s is currently running - we'll handle stopping/starting automatically
	$setupInfo = Get-SetupInfo
	$wasRunning = $false
	if ($setupInfo.Name) {
		$clusterState = Get-RunningState -SetupName $setupInfo.Name
		$wasRunning = ($clusterState.IsRunning -eq $true)
		if ($wasRunning) {
			Write-Log '[Update] K2s is currently running - will stop after applying Debian packages' -Console:$consoleSwitch
		} else {
			Write-Log '[Update] K2s is not running' -Console:$consoleSwitch
		}
	}

	$phaseId = 0
	function _phase { param($name) if ($ShowProgress) { $script:phaseId++; Write-Progress -Activity 'Cluster delta update' -Id 1 -Status ("{0}" -f $name) -PercentComplete (($script:phaseId) * 100 / 10) } Write-Log ("[Update] Phase: {0}" -f $name) -Console:$consoleSwitch }

	# 1. Load manifest from delta root
	_phase 'Manifest'
	$manifestRaw = Get-Content -LiteralPath $manifestPath -Raw
	try { $manifest = $manifestRaw | ConvertFrom-Json } catch { Write-Log ("[Update][Error] Manifest parse failed: {0}" -f $_.Exception.Message) -Console; return $false }
	Write-Log ("[Update] Manifest loaded: Added={0} Changed={1} Removed={2}" -f $manifest.AddedCount, $manifest.ChangedCount, $manifest.RemovedCount) -Console:$consoleSwitch

	# 2. Get target installation folder
	_phase 'DetectTarget'
	try {
		$targetInstallPath = Get-ClusterInstalledFolder
		Write-Log ("[Update] Target installation folder: {0}" -f $targetInstallPath) -Console:$consoleSwitch
		
		if (-not (Test-Path -LiteralPath $targetInstallPath)) {
			Write-Log ("[Update][Error] Target installation folder does not exist: {0}" -f $targetInstallPath) -Console
			return $false
		}
	} catch {
		Write-Log ("[Update][Error] Failed to determine target installation folder: {0}" -f $_.Exception.Message) -Console
		return $false
	}

	# 3. Validate version compatibility
	_phase 'VersionValidation'
	
	# Get the currently installed cluster version from the target installation folder
	try {
		$currentVersion = Get-ProductVersionGivenKubePath -KubePathLocal $targetInstallPath
		Write-Log ("[Update] Current installed version: {0} (from {1})" -f $currentVersion, $targetInstallPath) -Console:$consoleSwitch
	} catch {
		Write-Log ("[Update][Error] Failed to get current installed version: {0}" -f $_.Exception.Message) -Console
		return $false
	}
	
	$deltaBasePackage = [string]$manifest.BasePackage
	$deltaTargetPackage = [string]$manifest.TargetPackage
	
	# Use version fields directly from manifest (populated from VERSION files during delta generation)
	# Fall back to parsing package name for backward compatibility with older manifests
	function _ExtractVersionFromPackage([string]$packageName) {
		if ([string]::IsNullOrWhiteSpace($packageName)) { return $null }
		# Match patterns like k2s-v1.6.0, k2s-1.6.0, or just 1.6.0
		if ($packageName -match 'k2s-?v?(\d+\.\d+\.\d+)') { return $matches[1] }
		# Fallback: try to find version pattern anywhere in the name
		if ($packageName -match '(\d+\.\d+\.\d+)') { return $matches[1] }
		return $null
	}
	
	# Prefer explicit version fields from manifest; fall back to filename parsing for older manifests
	$deltaBaseVersion = if (-not [string]::IsNullOrWhiteSpace($manifest.BaseVersion)) { 
		$manifest.BaseVersion.Trim() 
	} else { 
		_ExtractVersionFromPackage $deltaBasePackage 
	}
	$deltaTargetVersion = if (-not [string]::IsNullOrWhiteSpace($manifest.TargetVersion)) { 
		$manifest.TargetVersion.Trim() 
	} else { 
		_ExtractVersionFromPackage $deltaTargetPackage 
	}
	
	Write-Log ("[Update] Version Check: Current={0}, DeltaBase={1}, DeltaTarget={2}" -f $currentVersion, $deltaBaseVersion, $deltaTargetVersion) -Console:$consoleSwitch
	
	# Validate that current system version matches delta base version
	if ($deltaBaseVersion -and $currentVersion -ne $deltaBaseVersion) {
		$errorMsg = "[Update][Error] Version mismatch: Current system version '{0}' does not match delta base version '{1}'. Delta package '{2}' cannot be applied to this system." -f $currentVersion, $deltaBaseVersion, $deltaBasePackage
		Write-Log $errorMsg -Console
		return $false
	}
	
	if (-not $deltaBaseVersion) {
		Write-Log ("[Update][Warn] Could not extract base version from package name '{0}'. Proceeding without version validation." -f $deltaBasePackage) -Console:$consoleSwitch
	} else {
		Write-Log ("[Update] Version validation passed: Delta base version '{0}' matches current system version '{1}'" -f $deltaBaseVersion, $currentVersion) -Console:$consoleSwitch
	}
	
	if ($deltaTargetVersion) {
		Write-Log ("[Update] Target version after update: {0}" -f $deltaTargetVersion) -Console:$consoleSwitch
	}

	# 4. Debian package delta (apply while cluster is running if needed)
	_phase 'DebianPackages'
	if ($manifest.DebianDeltaRelativePath) {
		$debDir = Join-Path $deltaRoot $manifest.DebianDeltaRelativePath
		$applyScript = Join-Path $debDir 'apply-debian-delta.sh'
		if (Test-Path -LiteralPath $applyScript) {
			if ($wasRunning) {
				Write-Log '[Update] Applying Debian delta while cluster is running...' -Console:$consoleSwitch
				try {
					# Direct invocation; module now provides Invoke-CommandInMasterVM
					Invoke-CommandInMasterVM -ScriptPath $applyScript -WorkingDirectory $debDir -ShowLogs:$ShowLogs
					Write-Log '[Update] Debian delta applied successfully.' -Console:$consoleSwitch
				} catch { 
					Write-Log ("[Update][Error] Debian delta execution failed: {0}" -f $_.Exception.Message) -Console
					throw
				}
			} else {
				Write-Log '[Update][Warn] Cluster not running - cannot apply Debian delta. Will skip Debian updates.' -Console:$consoleSwitch
			}
		} else {
			Write-Log '[Update][Info] No Debian delta apply script found; skipping' -Console:$consoleSwitch
		}
	} else { Write-Log '[Update] No Debian delta in manifest' -Console:$consoleSwitch }

	# 5. Stop cluster if it was running
	_phase 'StopCluster'
	if ($wasRunning) {
		Write-Log '[Update] Stopping K2s cluster to apply Windows artifacts...' -Console
		try {
			if (Get-Command -Name Stop-ClusterNode -ErrorAction SilentlyContinue) {
				Stop-ClusterNode -SetupName $setupInfo.Name -ShowLogs:$ShowLogs
				Write-Log '[Update] K2s cluster stopped successfully.' -Console:$consoleSwitch
			} else {
				Write-Log '[Update][Warn] Stop-ClusterNode not available; attempting k2s.exe stop from target folder...' -Console:$consoleSwitch
				$k2sExe = Join-Path $targetInstallPath 'k2s.exe'
				if (Test-Path -LiteralPath $k2sExe) {
					& $k2sExe stop
					if ($LASTEXITCODE -ne 0) { throw "k2s.exe stop returned exit code $LASTEXITCODE" }
					Write-Log '[Update] K2s cluster stopped successfully.' -Console:$consoleSwitch
				} else {
					throw "k2s.exe not found at $k2sExe"
				}
			}
		} catch {
			Write-Log ("[Update][Error] Failed to stop K2s cluster: {0}" -f $_.Exception.Message) -Console
			throw
		}
	} else {
		Write-Log '[Update] Cluster was not running; skipping stop phase.' -Console:$consoleSwitch
	}

	# 6. Apply Windows artifacts (Added + Changed) from delta root to target install path
	_phase 'WindowsArtifacts'
	Write-Log ("[Update] Applying artifacts from delta root '{0}' to target '{1}'" -f $deltaRoot, $targetInstallPath) -Console:$consoleSwitch
	$addedFiles   = @($manifest.Added)
	$changedFiles = @($manifest.Changed)
	$filesToApply = @($addedFiles + $changedFiles) | Where-Object { $_ -and ($_ -ne '') }
	foreach ($rel in $filesToApply) {
		$src = Join-Path $deltaRoot $rel
		if (-not (Test-Path -LiteralPath $src)) { Write-Log ("[Update][Warn] Source missing in delta: {0}" -f $rel) -Console:$consoleSwitch; continue }
		$dest = Join-Path $targetInstallPath $rel
		$destDir = Split-Path $dest -Parent
		if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
		
		try { 
			Copy-Item -LiteralPath $src -Destination $dest -Force 
			Write-Log ("[Update] Applied: {0}" -f $rel) -Console:$consoleSwitch
		} catch { 
			Write-Log ("[Update][Error] Copy failed '{0}' -> '{1}': {2}" -f $src, $dest, $_.Exception.Message) -Console 
		}
	}
	Write-Log ("[Update] Applied {0} Windows artifacts" -f $filesToApply.Count) -Console:$consoleSwitch

	# 7. Restart cluster if it was running before
	_phase 'RestartCluster'
	if ($wasRunning) {
		Write-Log '[Update] Restarting K2s cluster...' -Console
		try {
			if (Get-Command -Name Start-ClusterNode -ErrorAction SilentlyContinue) {
				Start-ClusterNode -SetupName $setupInfo.Name -ShowLogs:$ShowLogs
				Write-Log '[Update] K2s cluster restarted successfully.' -Console:$consoleSwitch
			} else {
				Write-Log '[Update][Warn] Start-ClusterNode not available; attempting k2s.exe start from target folder...' -Console:$consoleSwitch
				$k2sExe = Join-Path $targetInstallPath 'k2s.exe'
				if (Test-Path -LiteralPath $k2sExe) {
					& $k2sExe start
					if ($LASTEXITCODE -ne 0) { throw "k2s.exe start returned exit code $LASTEXITCODE" }
					Write-Log '[Update] K2s cluster restarted successfully.' -Console:$consoleSwitch
				} else {
					throw "k2s.exe not found at $k2sExe"
				}
			}
		} catch {
			Write-Log ("[Update][Error] Failed to restart K2s cluster: {0}" -f $_.Exception.Message) -Console
			Write-Log '[Update][Error] You may need to manually start the cluster: k2s start' -Console
			throw
		}
	} else {
		Write-Log '[Update] Cluster was not running before update; not restarting.' -Console:$consoleSwitch
	}

	# 8. Container images (if any .tar/.gz under delta/images)
	_phase 'Images'
	$imagesRoot = Join-Path $deltaRoot 'images'
	if (Test-Path -LiteralPath $imagesRoot) {
		$imageFiles = Get-ChildItem -LiteralPath $imagesRoot -Recurse -File -Include '*.tar','*.tar.gz','*.tgz' -ErrorAction SilentlyContinue
		if ($imageFiles.Count -gt 0) {
			Write-Log ("[Update] Loading {0} container image archives" -f $imageFiles.Count) -Console:$consoleSwitch
			foreach ($img in $imageFiles) {
				try {
					if (Get-Command -Name Import-K2sImageArchive -ErrorAction SilentlyContinue) {
						Import-K2sImageArchive -ArchivePath $img.FullName -ShowLogs:$ShowLogs
					} elseif (Get-Command -Name Load-K2sImage -ErrorAction SilentlyContinue) {
						Load-K2sImage -Path $img.FullName -ShowLogs:$ShowLogs
					} else {
						Write-Log ("[Update][Warn] No image import function available for {0}" -f $img.Name) -Console:$consoleSwitch
					}
				} catch { Write-Log ("[Update][Warn] Image load failed {0}: {1}" -f $img.Name, $_.Exception.Message) -Console:$consoleSwitch }
			}
		} else { Write-Log '[Update] No image archives found.' -Console:$consoleSwitch }
	} else { Write-Log '[Update] images/ directory absent; skipping image load' -Console:$consoleSwitch }

	# 8. Hooks placeholder
	_phase 'Hooks'
	if ($ExecuteHooks) { Write-Log '[Update][Info] Hooks execution placeholder (none implemented).' -Console:$consoleSwitch } else { Write-Log '[Update] Hooks disabled.' -Console:$consoleSwitch }

	# 9. Health check
	_phase 'Health'
	try {
		if ($wasRunning) {
			Write-Log '[Update] Performing health check on restarted cluster...' -Console:$consoleSwitch
			if (Get-Command -Name Wait-ForAPIServer -ErrorAction SilentlyContinue) { Wait-ForAPIServer -TimeoutSeconds 60 }
			if (Get-Command -Name Get-NodeReadySummary -ErrorAction SilentlyContinue) { $summary = Get-NodeReadySummary; Write-Log ("[Update] Node readiness: {0}" -f $summary) -Console:$consoleSwitch }
		} else {
			Write-Log '[Update] Skipping health check (cluster not running)' -Console:$consoleSwitch
		}
	} catch { Write-Log ("[Update][Warn] Health check encountered issues: {0}" -f $_.Exception.Message) -Console:$consoleSwitch }

	# 10. Update VERSION file to reflect successful delta update
	_phase 'UpdateVersion'
	if ($deltaTargetVersion) {
		try {
			# Update VERSION file in the target installation
			$versionFile = Join-Path $targetInstallPath 'VERSION'
			
			if (Test-Path -LiteralPath $versionFile) {
				Write-Log ("[Update] Updating VERSION file from {0} to {1}" -f $currentVersion, $deltaTargetVersion) -Console:$consoleSwitch
				$deltaTargetVersion | Out-File -FilePath $versionFile -Encoding ASCII -Force -NoNewline
				Write-Log ("[Update] VERSION file updated successfully: {0}" -f $versionFile) -Console:$consoleSwitch
			} else {
				Write-Log ("[Update][Warn] VERSION file not found at expected location: {0}" -f $versionFile) -Console:$consoleSwitch
			}
			
			# Update setup.json configuration to reflect the new version
			Write-Log ("[Update] Updating setup.json product version from {0} to {1}" -f $currentVersion, $deltaTargetVersion) -Console:$consoleSwitch
			Set-ConfigProductVersion -Value $deltaTargetVersion
			Write-Log '[Update] Setup configuration updated successfully' -Console:$consoleSwitch
		} catch {
			Write-Log ("[Update][Warn] Failed to update version information: {0}" -f $_.Exception.Message) -Console:$consoleSwitch
		}
	} else {
		Write-Log '[Update][Info] Target version not determined; version information not updated' -Console:$consoleSwitch
	}

	Write-Log '[Update] Delta update complete.' -Console:$consoleSwitch
	Write-Log ("[Update] Delta artifacts remain in: {0}" -f $deltaRoot) -Console:$consoleSwitch
	Write-Log '[Update] You may safely delete the extracted delta package directory after verifying the update.' -Console:$consoleSwitch

	if ($ShowProgress) { Write-Progress -Activity 'Cluster delta update' -Id 1 -Completed }
	
	return $true
}

Export-ModuleMember -Function PerformClusterUpdate

# region: VM execution helper (Debian delta application)
function Invoke-CommandInMasterVM {
	<#
	.SYNOPSIS
		Copies a host-staged script into the running Hyper-V control plane VM (kubemaster) and executes it.
	.DESCRIPTION
		Reuses existing SSH/key infrastructure exposed by linuxnode vm module (Invoke-CmdOnControlPlaneViaSSHKey,
		Copy-ToControlPlaneViaSSHKey). Assumes Hyper-V (not WSL) environment. Designed primarily for applying the
		Debian delta script generated in a delta package. Provides timing, optional log streaming, and structured
		result object.
	.PARAMETER ScriptPath
		Absolute path on the Windows host to the script to execute (e.g. apply-debian-delta.sh).
	.PARAMETER WorkingDirectory
		Optional host directory containing related assets; copied recursively if provided (only the script is
		required). Defaults to the script's parent directory. Directory contents are placed under /tmp/k2s-delta-deb.
	.PARAMETER ShowLogs
		If set, echo remote stdout/stderr lines (underlying helpers already log; we add phase headers).
	.PARAMETER TimeoutSeconds
		Overall timeout for the remote execution attempt. Does not forcibly kill remote process beyond plink exit.
	.PARAMETER RetryCount
		Number of SSH retries for transient failures (mapped to existing helper retry semantics).
	.PARAMETER NoThrow
		Return result object even if exit code != 0 (caller handles).
	.OUTPUTS
		PSCustomObject { ExitCode; DurationSeconds; RemotePath; Success; }
	.NOTES
		EXPERIMENTAL: May evolve to include cleanup logic or hash verification of script.
	#>
	[CmdletBinding()] param(
		[Parameter(Mandatory=$true)][string] $ScriptPath,
		[string] $WorkingDirectory = '',
		[switch] $ShowLogs,
		[int] $TimeoutSeconds = 900,
		[int] $RetryCount = 0,
		[switch] $NoThrow
	)

	$consoleSwitch = $ShowLogs
	if ([string]::IsNullOrWhiteSpace($ScriptPath)) { throw 'ScriptPath is required.' }
	if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "ScriptPath not found: $ScriptPath" }

	# Import vm module to access SSH helpers (idempotent import)
	$vmModule = "$PSScriptRoot/../../k2s.node.module/linuxnode/vm/vm.module.psm1"
	if (Test-Path -LiteralPath $vmModule) { Import-Module $vmModule -ErrorAction SilentlyContinue }
	if (-not (Get-Command -Name Invoke-CmdOnControlPlaneViaSSHKey -ErrorAction SilentlyContinue)) {
		throw 'Invoke-CmdOnControlPlaneViaSSHKey not available (vm module not imported)'
	}
	if (-not (Get-Command -Name Copy-ToControlPlaneViaSSHKey -ErrorAction SilentlyContinue)) {
		throw 'Copy-ToControlPlaneViaSSHKey not available (vm module not imported)'
	}
	# Ensure control plane VM is running (Hyper-V path). If WSL is enabled, skip Hyper-V start logic.
	$wslEnabled = $false
	if (Get-Command -Name Get-ConfigWslFlag -ErrorAction SilentlyContinue) {
		try { $wslEnabled = (Get-ConfigWslFlag) } catch { $wslEnabled = $false }
	}
	if (-not $wslEnabled) {
		# Import vmnode module for Start-VirtualMachine / Wait helpers if available
		$vmNodeModule = "$PSScriptRoot/../../k2s.node.module/vmnode/vmnode.module.psm1"
		if (Test-Path -LiteralPath $vmNodeModule) { Import-Module $vmNodeModule -ErrorAction SilentlyContinue }
		$cpRunning = $false
		if (Get-Command -Name Get-IsControlPlaneRunning -ErrorAction SilentlyContinue) {
			try { $cpRunning = Get-IsControlPlaneRunning } catch { $cpRunning = $false }
		}
		if (-not $cpRunning) {
			if (-not $NoThrow) { throw 'Control plane VM not running; cannot apply Debian delta.' }
			return [pscustomobject]@{ ExitCode = 100; DurationSeconds = 0; RemotePath = $null; Success = $false }
		}
		if ($cpRunning -and (Get-Command -Name Wait-ForSSHConnectionToLinuxVMViaSshKey -ErrorAction SilentlyContinue)) {
			Write-Log '[DebPkg][VM] Waiting for SSH availability' -Console:$consoleSwitch
			try { Wait-ForSSHConnectionToLinuxVMViaSshKey } catch { Write-Log "[DebPkg][VM][Warn] SSH wait failed: $($_.Exception.Message)" -Console:$consoleSwitch }
		}
	}

	$scriptDir = Split-Path -Parent $ScriptPath
	if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) { $WorkingDirectory = $scriptDir }
	if (-not (Test-Path -LiteralPath $WorkingDirectory)) { throw "WorkingDirectory not found: $WorkingDirectory" }

	$remoteBase = '/tmp/k2s-delta-deb'
	$remoteScriptName = Split-Path -Leaf $ScriptPath
	$remoteScriptPath = "$remoteBase/$remoteScriptName"

	Write-Log "[DebPkg][VM] Staging Debian delta script '$remoteScriptName'" -Console:$consoleSwitch
	try {
		# Ensure remote directory and make it writable by the user
		(Invoke-CmdOnControlPlaneViaSSHKey "sudo mkdir -p $remoteBase && sudo chown `$(whoami) $remoteBase" -Retries $RetryCount -Timeout 2).Output | Out-Null

		# Copy only the script (avoid large recursive transfers unless needed)
		Copy-ToControlPlaneViaSSHKey -Source $ScriptPath -Target $remoteBase -IgnoreErrors:$false
		# If ancillary assets exist (packages/, etc.) we copy directory selectively
		$packagesDir = Join-Path $WorkingDirectory 'packages'
		if (Test-Path -LiteralPath $packagesDir) {
			Write-Log '[DebPkg][VM] Copying packages/ directory' -Console:$consoleSwitch
			Copy-ToControlPlaneViaSSHKey -Source $packagesDir -Target $remoteBase -IgnoreErrors:$false
		}
		# Make executable
		(Invoke-CmdOnControlPlaneViaSSHKey "sudo chmod +x $remoteScriptPath" -Retries $RetryCount -Timeout 2 -IgnoreErrors:$false).Output | Out-Null
	} catch {
		throw "Failed to stage script in master VM: $($_.Exception.Message)"
	}

	Write-Log '[DebPkg][VM] Executing Debian delta script inside control plane VM' -Console:$consoleSwitch
	$start = Get-Date
	$execCmd = "sudo $remoteScriptPath"
	$elapsed = $null
	$exitCode = -1
	$success = $false
	$outputAggregate = @()
	try {
		$attempts = 0
		$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
		while ($true) {
			$result = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute $execCmd -Retries $RetryCount -Timeout 3 -IgnoreErrors:$true
			$exitCode = $LASTEXITCODE
			$success = ($exitCode -eq 0)
			$outputAggregate += $result.Output
			if ($success -or (Get-Date) -ge $deadline) { break }
			Start-Sleep -Seconds 2
			$attempts++
		}
		$elapsed = (Get-Date) - $start
	} catch {
		$elapsed = (Get-Date) - $start
		if (-not $NoThrow) { throw "Debian delta script execution failed: $($_.Exception.Message)" }
	}
	$durationSec = [Math]::Round($elapsed.TotalSeconds,2)
	Write-Log ("[DebPkg][VM] Script completed exit={0} duration={1}s" -f $exitCode, $durationSec) -Console:$consoleSwitch
	if (-not $success -and -not $NoThrow) { throw "Debian delta script returned non-zero exit code: $exitCode" }

	return [pscustomobject]@{ ExitCode = $exitCode; DurationSeconds = $durationSec; RemotePath = $remoteScriptPath; Success = $success }
}

Export-ModuleMember -Function Invoke-CommandInMasterVM -ErrorAction SilentlyContinue
# endregion
