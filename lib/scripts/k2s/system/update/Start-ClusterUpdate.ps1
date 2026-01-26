# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Starts the update of the cluster.

.DESCRIPTION
Starts the update of the cluster by doing an in-place upgrade.


.EXAMPLE
# Starts the update of the cluster
PS> .\Start-ClusterUpdate.ps1

#>

Param(
	[Parameter(Mandatory = $false, HelpMessage = 'Show progress bar')]
	[switch] $ShowProgress = $false,
	[parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
	[switch] $ShowLogs = $false
)

# Detect if running from delta package (delta-manifest.json 5 levels up)
$possibleDeltaRoot = Split-Path (Split-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) -Parent) -Parent
$deltaManifestPath = Join-Path $possibleDeltaRoot 'delta-manifest.json'
$runningFromDelta = Test-Path -LiteralPath $deltaManifestPath

if ($runningFromDelta) {
	# Running from delta package - reference modules from target installation
	Write-Host "[Update] Detected delta package context - loading modules from target installation" -ForegroundColor Cyan
	
	# Get target installation path from setup.json
	$setupConfigPath = "$env:SystemDrive\ProgramData\k2s\setup.json"
	if (Test-Path -LiteralPath $setupConfigPath) {
		$setupConfig = Get-Content -LiteralPath $setupConfigPath -Raw | ConvertFrom-Json
		$targetInstallPath = $setupConfig.InstallFolder
	} else {
		$targetInstallPath = 'C:\k'
	}
	
	if (-not (Test-Path -LiteralPath $targetInstallPath)) {
		Write-Host "[Update][Error] Target installation not found at: $targetInstallPath" -ForegroundColor Red
		exit 1
	}
	
	$infraModule = Join-Path $targetInstallPath 'lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1'
	$clusterModule = Join-Path $targetInstallPath 'lib\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1'
	$addonsModule = Join-Path $targetInstallPath 'addons\addons.module.psm1'
	
	# Load update module from target installation as well (not from delta package)
	# This ensures vm.module.psm1 and other dependencies resolve paths correctly via Get-KubePath
	$updateModule = Join-Path $targetInstallPath 'lib\modules\k2s\k2s.cluster.module\update\update.module.psm1'
} else {
	# Running from installed k2s - use relative paths
	$infraModule = "$PSScriptRoot/../../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
	$clusterModule = "$PSScriptRoot/../../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
	$addonsModule = "$PSScriptRoot/../../../../../addons\addons.module.psm1"
	$updateModule = "$PSScriptRoot/../../../../modules/k2s/k2s.cluster.module/update/update.module.psm1"
}

Import-Module $infraModule, $clusterModule, $addonsModule, $updateModule

Initialize-Logging -ShowLogs:$ShowLogs

<#
 .Synopsis
  Updates the K8s cluster to new version from current directory.

  .Description
  Updates the K8s cluster to new version from current directory.

  .PARAMETER ShowProgress
  If set to $true, shows the overalls progress on operation-level.

 .Example
  Start-ClusterUpdate

 .Example
  Start-ClusterUpdate -ShowProgress $true -SkipResources $false

 .OUTPUTS
  Status object
#>
function Start-ClusterUpdate {
	param(
		[Parameter(Mandatory = $false, HelpMessage = 'Show progress bar')]
		[switch] $ShowProgress = $false,
		[parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
		[switch] $ShowLogs = $false
	)
	$errUpdate = $null

	try {
		PerformClusterUpdate -ExecuteHooks:$true -ShowProgress:$ShowProgress -ShowLogs:$ShowLogs
	}
	catch {
		Write-Log 'System update failed' -Console
		Write-Log 'An ERROR occurred:' -Console
		Write-Log $_.ScriptStackTrace -Console
		Write-Log $_ -Console
		Write-Error 'System update failed, please check the logs for more information!'
		return $false
	}
	
	if ( $errUpdate ) {
		return $false
	}
}

#####################################################
###############START OF UPDATE#######################
#####################################################

Write-Log 'Starting updating cluster' -Console
Start-ClusterUpdate -ShowProgress:$ShowProgress -ShowLogs:$ShowLogs
