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
$statusModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/status/status.module.psm1"
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$commonModule = "$PSScriptRoot\common.module.psm1"

Import-Module $statusModule, $infraModule, $addonsModule, $commonModule

Initialize-Logging -ShowLogs:$ShowLogs

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
    return
  }

  Write-Log $systemError.Message -Error
  exit 1
}

if ( (Test-IsAddonEnabled -Name 'exthttpaccess') -ne $true) {
  $errMsg = "Addon 'exthttpaccess' is already disabled, nothing to do."

  if ($EncodeStructuredOutput -eq $true) {
    $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyDisabled) -Message $errMsg
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
  }
    
  Write-Log $errMsg -Error
  exit 1
}

Remove-Nginx
Remove-ScriptsFromHooksDir -ScriptNames @(Get-ChildItem -Path "$PSScriptRoot\hooks" | ForEach-Object { $_.Name })
Remove-AddonFromSetupJson -Name 'exthttpaccess'

Write-Log 'exthttpaccess disabled' -Console

if ($EncodeStructuredOutput -eq $true) {
  Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}