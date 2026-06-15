# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Starts the update of the cluster.

.DESCRIPTION
Starts the update of the cluster by completing the current delta package directory
and switching setup.json InstallFolder to that directory.


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
	# Running from delta package - reference modules from the existing installation until the delta folder is complete.
	Write-Host "[Update] Detected delta package context - loading base modules from existing installation" -ForegroundColor Cyan
	
	# Get existing installation path from setup.json
	$setupConfigPath = "$env:SystemDrive\ProgramData\k2s\setup.json"
	if (Test-Path -LiteralPath $setupConfigPath) {
		$setupConfig = Get-Content -LiteralPath $setupConfigPath -Raw | ConvertFrom-Json
		$existingInstallPath = $setupConfig.InstallFolder
	} else {
		$existingInstallPath = 'C:\k'
	}
	
	if (-not (Test-Path -LiteralPath $existingInstallPath)) {
		Write-Host "[Update][Error] Existing installation not found at: $existingInstallPath" -ForegroundColor Red
		exit 1
	}
	
	$infraModule = Join-Path $existingInstallPath 'lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1'
	$clusterModule = Join-Path $existingInstallPath 'lib\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1'
	$addonsModule = Join-Path $existingInstallPath 'addons\addons.module.psm1'
	
	# Load update module from DELTA PACKAGE (it's new/updated and may not exist in target installation)
	# Infrastructure modules are loaded from existing installation until PerformClusterUpdate switches setup.json.
	$updateModule = Join-Path $possibleDeltaRoot 'lib\modules\k2s\k2s.cluster.module\update\update.module.psm1'
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
