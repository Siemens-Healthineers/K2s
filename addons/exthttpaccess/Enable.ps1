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
  [parameter(Mandatory = $false, HelpMessage = 'HTTP port to use (valid range is 49152 to 65535)')]
  [string] $HttpPort = '',
  [parameter(Mandatory = $false, HelpMessage = 'HTTPS port to use (valid range is 49152 to 65535)')]
  [string] $HttpsPort = '',
  [parameter(Mandatory = $false, HelpMessage = 'Use the alternative ports 8080/8443 instead of 80/443 in case they are not free without user confirmation.')]
  [switch]$AutoconfirmUseAlternativePortsIfNeeded = $false,
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
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"

Import-Module $addonsModule, $logModule, $statusModule, $infraModule

Initialize-Logging -ShowLogs:$ShowLogs

# hooks handling
$hookFilePaths = @()
$hookFilePaths += Get-ChildItem -Path "$PSScriptRoot\hooks" | ForEach-Object { $_.FullName }

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
    return
  }

  Write-Log $systemError.Message -Error
  exit 1
}

if ((Test-IsAddonEnabled -Name 'exthttpaccess') -eq $true) {
  $errMsg = "Addon 'exthttpaccess' is already enabled, nothing to do."

  if ($EncodeStructuredOutput -eq $true) {
    $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
  }
  
  Write-Log $errMsg -Error
  exit 1
}

function Stop-ExecutionDueToPortValue {
  param (
    [string]$AbortMessage = $(throw 'Parameter missing: AbortMessage')
  )
  if ($EncodeStructuredOutput -eq $true) {
    $err = New-Error -Severity Warning -Code 'port-not-assignable' -Message $AbortMessage
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    exit 0
  }
  
  Write-Log $AbortMessage -Error
  exit 1
}

function Find-IsPortUsed {
  param (
    [string]$Port = $(throw 'Parameter missing: Port')
  )
  $processesListeningOnPort = netstat -aon | findstr ":$Port" | findstr 'LISTENING'

  return (![string]::IsNullOrWhiteSpace($processesListeningOnPort))
}

function Assert-UserConfiguredPortNumber {
  param (
    [string]$Port
  )
  $isNumber = $Port -match "^[0-9]*$"
  if (!$isNumber) {
    Stop-ExecutionDueToPortValue -AbortMessage "The user configured port value must be a number."
  }
  try {
    $portNumber = [int]$Port
  }
  catch {
    Stop-ExecutionDueToPortValue -AbortMessage "Could not convert port value '$Port' to a number."
  }
  
  if ($portNumber -lt 49152 -or $portNumber -gt 65535) {
    Stop-ExecutionDueToPortValue -AbortMessage "The user configured port number '$Port' cannot be used. Please choose a number between 49152 and 65535."
  }

  $isPortUsed = Find-IsPortUsed -Port $Port
  if ($isPortUsed) {
    Stop-ExecutionDueToPortValue -AbortMessage "The user configured port number '$Port' is already in use."
  }
}

$httpPortNumberToUse = '80'
$httpsPortNumberToUse = '443'

if ([string]::IsNullOrWhiteSpace($HttpPort) -and [string]::IsNullOrWhiteSpace($HttpsPort)) {
  $isPort80Used = Find-IsPortUsed -Port $httpPortNumberToUse
  $isPort443Used = Find-IsPortUsed -Port $httpsPortNumberToUse

  if ($isPort80Used -or $isPort443Used) {

    if ($AutoconfirmUseAlternativePortsIfNeeded) {
      $useAlternativePorts = 0
    }
    else {
      $title = 'The ports 80 and/or 443 are already in use.'
      $question = 'Do you want to use the alternative ports 8080/8443 instead?'
      $choices = @(
        [System.Management.Automation.Host.ChoiceDescription]::new('&Yes', 'Use the alternative ports 8080/8443.')
        [System.Management.Automation.Host.ChoiceDescription]::new('&No', 'Abort the addon enabling.')
      )
      $useAlternativePorts = $Host.UI.PromptForChoice($title, $question, $choices, 0)
    }
    
    if ($useAlternativePorts -eq 0) {
      $httpPortNumberToUse = '8080'
      $httpsPortNumberToUse = '8443'
      $isPort8080Used = Find-IsPortUsed -Port $httpPortNumberToUse
      $isPort8443Used = Find-IsPortUsed -Port $httpsPortNumberToUse

      if ($isPort8080Used -or $isPort8443Used) {
        Stop-ExecutionDueToPortValue -AbortMessage 'The addon still cannot be enabled since there is already a process listening on port 8080 and/or 8443.'
      }
    }
    else {
      Stop-ExecutionDueToPortValue -AbortMessage 'The addon cannot be enabled since there is already a process listening on port 80 and/or 443.'
    }
  }
} else {

  if ($HttpPort -eq $HttpsPort) {
    Stop-ExecutionDueToPortValue -AbortMessage "The user configured port values for HTTP and HTTPS are the same."
  }
  Assert-UserConfiguredPortNumber -Port $HttpPort
  Assert-UserConfiguredPortNumber -Port $HttpsPort

  $httpPortNumberToUse = $HttpPort
  $httpsPortNumberToUse = $HttpsPort

}

Write-Log 'Obtaining IPs of active physical net adapters' -Console
$na = (Get-NetAdapter -Physical | Where-Object { ($_.Status -eq 'Up') -and ($_.Name -ne 'Loopbackk2s') })
$physicalIps = (Get-NetIPAddress -InterfaceAlias $na.ifAlias -AddressFamily IPv4).IPAddress

if ($physicalIps.Count -lt 1) {
  $errMsg = 'There is no physical net adapter detected that could be used to enable external HTTP/HTTPS access'

  if ($EncodeStructuredOutput -eq $true) {
    $err = New-Error -Code 'no-net-adapter' -Message $errMsg
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
  }

  Write-Log $errMsg -Error
  exit 1
}

Write-Log 'Creating nginx configuration file' -Console
$listen_block_https_port = ''
$listen_block_http_port = ''
foreach ($ip in $physicalIps) {
  $listen_block_https_port = "${listen_block_https_port}        listen ${ip}:$httpsPortNumberToUse;`r`n"
  $listen_block_http_port = "${listen_block_http_port}        listen ${ip}:$httpPortNumberToUse;`r`n"
}
$variablesHash = @{}
$variablesHash['listen_block_https_port'] = $listen_block_https_port;
$variablesHash['listen_block_http_port'] = $listen_block_http_port;
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
        $err = New-Error -Code 'addon-template-invalid' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
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
&$global:NssmInstallDirectory\nssm install nginx-ext $global:BinPath\nginx\nginx.exe | Write-Log
&$global:NssmInstallDirectory\nssm set nginx-ext AppDirectory "$global:BinPath\nginx" | Out-Null
&$global:NssmInstallDirectory\nssm set nginx-ext AppParameters -c "`"""$global:BinPath\nginx\nginx.conf`"""" -e "$($global:SystemDriveLetter):\var\log\nginx\nginx_stderr.log" | Out-Null
&$global:NssmInstallDirectory\nssm set nginx-ext AppStdout "$($global:SystemDriveLetter):\var\log\nginx\nginx_stdout.log" | Out-Null
&$global:NssmInstallDirectory\nssm set nginx-ext AppStderr "$($global:SystemDriveLetter):\var\log\nginx\nginx_stderr.log" | Out-Null
&$global:NssmInstallDirectory\nssm set nginx-ext AppStdoutCreationDisposition 4 | Out-Null
&$global:NssmInstallDirectory\nssm set nginx-ext AppStderrCreationDisposition 4 | Out-Null
&$global:NssmInstallDirectory\nssm set nginx-ext AppRotateFiles 1 | Out-Null
&$global:NssmInstallDirectory\nssm set nginx-ext AppRotateOnline 1 | Out-Null
&$global:NssmInstallDirectory\nssm set nginx-ext AppRotateSeconds 0 | Out-Null
&$global:NssmInstallDirectory\nssm set nginx-ext AppRotateBytes 500000 | Out-Null
&$global:NssmInstallDirectory\nssm set nginx-ext Start SERVICE_AUTO_START | Out-Null
&$global:NssmInstallDirectory\nssm start nginx-ext | Write-Log

Copy-ScriptsToHooksDir -ScriptPaths $hookFilePaths
Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'exthttpaccess' })

Write-Log 'exthttpaccess enabled' -Console

if ($EncodeStructuredOutput -eq $true) {
  Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}