# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Disables nginx from the windows machine where this script is running

.DESCRIPTION
Nginx is needed to handle HTTP/HTTPS request comming to windows machine from local or external network
in order to handle such request by kubernetes load balancer/ingress service

.EXAMPLE
powershell <installation folder>\addons\exthttpaccess\Disable.ps1
#>

Param(
  [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
  [switch] $ShowLogs = $false
)

$mainStopwatch = [system.diagnostics.stopwatch]::StartNew()

# load global settings
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1

Import-Module "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
Initialize-Logging -ShowLogs:$ShowLogs

$addonsModule = "$PSScriptRoot\..\Addons.module.psm1"

Import-Module $addonsModule

# stop nginx service
Write-Log 'Stop nginx service' -Console
&$global:NssmInstallDirectory\nssm stop ExtHttpAccess-nginx | Write-Log

# remove nginx service
Write-Log 'Remove nginx service' -Console
&$global:NssmInstallDirectory\nssm remove ExtHttpAccess-nginx confirm | Write-Log

# cleanup installation directory
Remove-Item -Recurse -Force "$global:BinPath\nginx" | Out-Null

Remove-AddonFromSetupJson -Name 'exthttpaccess'

Write-Log "Total duration: $('{0:hh\:mm\:ss}' -f $mainStopwatch.Elapsed )" -Console
