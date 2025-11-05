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
$infraModule = "$PSScriptRoot/../../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot/../../../../../addons\addons.module.psm1"


Import-Module $infraModule, $clusterModule, $addonsModule

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
		Write-Log 'System update failed '
		try {
			 # backup log file since it will be deleted during uninstall
			$logFilePathBeforeUninstall.Value = Join-Path $BackupDir 'k2s-before-uninstall.log'
		}
		catch {
			Write-Log 'An ERROR occurred:' -Console
			Write-Log $_.ScriptStackTrace -Console
			Write-Log $_ -Console
			Write-Error 'System update failed, please check the logs for more information !'
			return $false
		}
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
