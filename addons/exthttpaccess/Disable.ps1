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
  [switch] $ShowLogs = $false,
  [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
  [switch] $EncodeStructuredOutput,
  [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
  [string] $MessageType
)
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1

$logModule = "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
$statusModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/status/status.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$cliMessagesModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/cli-messages/cli-messages.module.psm1"

Import-Module $logModule, $addonsModule, $statusModule, $cliMessagesModule

Initialize-Logging -ShowLogs:$ShowLogs

# hooks handling
$hookFileNames = @()
$hookFileNames += Get-ChildItem -Path "$PSScriptRoot\hooks" | ForEach-Object { $_.Name }

$systemError = Test-SystemAvailability
if ($systemError) {
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
    return
  }

  Write-Log $systemError -Error
  exit 1
}

if ( (Test-IsAddonEnabled -Name 'exthttpaccess') -ne $true) {
  Write-Log "Addon 'exthttpaccess' is already disabled, nothing to do." -Console

  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
  }
  
  exit 0
}

# stop nginx service
Write-Log 'Stop nginx service' -Console
&$global:NssmInstallDirectory\nssm stop nginx-ext | Write-Log

# remove nginx service
Write-Log 'Remove nginx service' -Console
&$global:NssmInstallDirectory\nssm remove nginx-ext confirm | Write-Log

# cleanup installation directory
Remove-Item -Recurse -Force "$global:BinPath\nginx" | Out-Null

Remove-ScriptsFromHooksDir -ScriptNames $hookFileNames
Remove-AddonFromSetupJson -Name 'exthttpaccess'

Write-Log 'exthttpaccess disabled' -Console

if ($EncodeStructuredOutput -eq $true) {
  Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}