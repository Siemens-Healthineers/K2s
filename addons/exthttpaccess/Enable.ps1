# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Enables nginx on the windows machine from where this script is running

.DESCRIPTION
Nginx is needed to handle HTTP/HTTPS request coming to windows machine from local or external network
in order to handle such request by kubernetes load balancer/ingress service

.EXAMPLE
# For k2sSetup
powershell <installation folder>\addons\exthttpaccess\Enable.ps1
# For k2sSetup behind proxy
powershell <installation folder>\addons\exthttpaccess\Enable.ps1 -Proxy http://139.22.102.14:8888
#>
Param(
  [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
  [switch] $ShowLogs = $false,
  [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
  [string] $Proxy = '',
  [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
  [pscustomobject] $Config,
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

Import-Module $addonsModule, $logModule, $statusModule, $cliMessagesModule

Initialize-Logging -ShowLogs:$ShowLogs

$systemError = Test-SystemAvailability
if ($systemError) {
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
    return
  }

  Write-Log $systemError -Error
  exit 1
}

if ((Test-IsAddonEnabled -Name 'dashboard') -eq $true) {
  Write-Log "Addon 'dashboard' is already enabled, nothing to do." -Console

  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
  }
  
  exit 0
}

Write-Log 'Obtaining IPs of active physical net adapters' -Console
$na = (Get-NetAdapter -Physical | Where-Object { ($_.Status -eq 'Up') -and ($_.Name -ne 'Loopbackk2s') })
$physicalIps = (Get-NetIPAddress -InterfaceAlias $na.ifAlias -AddressFamily IPv4).IPAddress

if ($physicalIps.Count -lt 1) {
  $errMsg = 'There is no physical net adapter detected that could be used to enable external HTTP/HTTPS access'

  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $errMsg }
    return
  }

  Write-Log $errMsg -Error
  exit 1
}

Write-Log 'Creating nginx configuration file' -Console
$listen_block_443 = ''
$listen_block_80 = ''
foreach ($ip in $physicalIps) {
  $listen_block_443 = "${listen_block_443}        listen ${ip}:443;`r`n"
  $listen_block_80 = "${listen_block_80}        listen ${ip}:80;`r`n"
}
$variablesHash = @{}
$variablesHash['listen_block_443'] = $listen_block_443;
$variablesHash['listen_block_80'] = $listen_block_80;
$variablesHash['master_ip'] = $global:IP_Master;

mkdir -Force "$global:BinPath\nginx" | Out-Null
$mustachePattern = '({{\s*[\w\-]+\s*(\|\s*[\w]+\s*)*}})|({{{\s*[\w\-]+\s*(\|\s*[\w]+\s*)*}}})'
Get-Content "$global:KubernetesPath\addons\exthttpaccess\nginx.tmp" | ForEach-Object {
  $line = $_
  $matchResult = $line | Select-String $mustachePattern -AllMatches
  ForEach ($match in $matchResult.Matches.Value) {
    $variableName = $match -replace '[\s{}]', ''
    $variableValue = $variablesHash[$variableName]
    if (!$variablesHash.ContainsKey($variableName)) {
      $errMsg = "Didn't you forget to specify variable `${variableName}` for your nginx.tmp template?"
  
      if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $errMsg }
        exit 0
      }

      Write-Log $errMsg -Error
      exit 1
    }
    $line = $line -replace [regex]::Escape($match), $variableValue
  }
  $line
} | out-file "$global:BinPath\nginx\nginx.conf" -encoding ascii

Write-Log 'Downloading nginx executable' -Console
if (!(Test-Path "$global:BinPath\nginx\nginx.zip")) {
  DownloadFile "$global:BinPath\nginx\nginx.zip" https://nginx.org/download/nginx-1.23.2.zip $true -ProxyToUse $Proxy
}

tar C "$global:BinPath\nginx" -xvf "$global:BinPath\nginx\nginx.zip" --strip-components 1 *.exe 2>&1 | % { "$_" }
Remove-Item -Force "$global:BinPath\nginx\nginx.zip"
mkdir -Force "$global:BinPath\nginx\temp" | Out-Null
mkdir -Force "$global:BinPath\nginx\logs" | Out-Null

Write-Log 'Registering nginx service' -Console
mkdir -Force "$($global:SystemDriveLetter):\var\log\nginx" | Out-Null
&$global:NssmInstallDirectory\nssm install ExtHttpAccess-nginx $global:BinPath\nginx\nginx.exe | Write-Log
&$global:NssmInstallDirectory\nssm set ExtHttpAccess-nginx AppDirectory "$global:BinPath\nginx" | Out-Null
&$global:NssmInstallDirectory\nssm set ExtHttpAccess-nginx AppParameters -c "`"""$global:BinPath\nginx\nginx.conf`"""" -e "$($global:SystemDriveLetter):\var\log\nginx\nginx_stderr.log" | Out-Null
&$global:NssmInstallDirectory\nssm set ExtHttpAccess-nginx AppStdout "$($global:SystemDriveLetter):\var\log\nginx\nginx_stdout.log" | Out-Null
&$global:NssmInstallDirectory\nssm set ExtHttpAccess-nginx AppStderr "$($global:SystemDriveLetter):\var\log\nginx\nginx_stderr.log" | Out-Null
&$global:NssmInstallDirectory\nssm set ExtHttpAccess-nginx AppStdoutCreationDisposition 4 | Out-Null
&$global:NssmInstallDirectory\nssm set ExtHttpAccess-nginx AppStderrCreationDisposition 4 | Out-Null
&$global:NssmInstallDirectory\nssm set ExtHttpAccess-nginx AppRotateFiles 1 | Out-Null
&$global:NssmInstallDirectory\nssm set ExtHttpAccess-nginx AppRotateOnline 1 | Out-Null
&$global:NssmInstallDirectory\nssm set ExtHttpAccess-nginx AppRotateSeconds 0 | Out-Null
&$global:NssmInstallDirectory\nssm set ExtHttpAccess-nginx AppRotateBytes 500000 | Out-Null
&$global:NssmInstallDirectory\nssm set ExtHttpAccess-nginx Start SERVICE_AUTO_START | Out-Null
&$global:NssmInstallDirectory\nssm start ExtHttpAccess-nginx | Write-Log

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'exthttpaccess' })

if ($EncodeStructuredOutput -eq $true) {
  Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}