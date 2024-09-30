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
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$exthttpaccessModule = "$PSScriptRoot\exthttpaccess.module.psm1"

Import-Module $infraModule, $clusterModule, $nodeModule, $addonsModule, $exthttpaccessModule

Initialize-Logging -ShowLogs:$ShowLogs

$Proxy = Get-OrUpdateProxyServer -Proxy:$Proxy

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
    return
  }

  Write-Log $systemError.Message -Error
  exit 1
}

$setupInfo = Get-SetupInfo
if ($setupInfo.Name -ne 'k2s') {
  $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon 'exthttpaccess' can only be enabled for 'k2s' setup type."  
  Send-ToCli -MessageType $MessageType -Message @{Error = $err }
  return
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'exthttpaccess' })) -eq $true) {
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
  $isNumber = $Port -match '^[0-9]*$'
  if (!$isNumber) {
    Stop-ExecutionDueToPortValue -AbortMessage 'The user configured port value must be a number.'
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
}
else {

  if ($HttpPort -eq $HttpsPort) {
    Stop-ExecutionDueToPortValue -AbortMessage 'The user configured port values for HTTP and HTTPS are the same.'
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
$variablesHash['master_ip'] = (Get-ConfiguredIPControlPlane);
$binPath = Get-KubeBinPath

mkdir -Force "$binPath\nginx" | Out-Null
$mustachePattern = '({{\s*[\w\-]+\s*(\|\s*[\w]+\s*)*}})|({{{\s*[\w\-]+\s*(\|\s*[\w]+\s*)*}}})'
Get-Content "$PSScriptRoot\nginx.tmp" | ForEach-Object {
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
} | out-file "$binPath\nginx\nginx.conf" -encoding ascii

Write-Log 'Downloading nginx executable' -Console
if (!(Test-Path "$binPath\nginx\nginx.zip")) {
  Invoke-DownloadFile "$binPath\nginx\nginx.zip" 'https://nginx.org/download/nginx-1.23.2.zip' $true -ProxyToUse $Proxy
}

tar C "$binPath\nginx" -xvf "$binPath\nginx\nginx.zip" --strip-components 1 *.exe 2>&1 | ForEach-Object { "$_" }
Remove-Item -Force "$binPath\nginx\nginx.zip"
mkdir -Force "$binPath\nginx\temp" | Out-Null
mkdir -Force "$binPath\nginx\logs" | Out-Null

$systemDrive = Get-SystemDriveLetter

Write-Log 'Registering nginx service' -Console
mkdir -Force "$($systemDrive):\var\log\nginx" | Out-Null

$serviceName = Get-ServiceName

Install-Service -Name $serviceName -ExePath "$binPath\nginx\nginx.exe"

Set-ServiceProperty -Name $serviceName -PropertyName 'AppDirectory' -Value "$binPath\nginx"
Set-ServiceProperty -Name $serviceName -PropertyName 'AppParameters' -Value "-c `"`"$binPath\nginx\nginx.conf`"`" -e `"$($systemDrive):\var\log\nginx\nginx_stderr.log`""
Set-ServiceProperty -Name $serviceName -PropertyName 'AppStdout' -Value "$($systemDrive):\var\log\nginx\nginx_stdout.log"
Set-ServiceProperty -Name $serviceName -PropertyName 'AppStderr' -Value "$($systemDrive):\var\log\nginx\nginx_stderr.log"
Set-ServiceProperty -Name $serviceName -PropertyName 'AppStdoutCreationDisposition' -Value 4
Set-ServiceProperty -Name $serviceName -PropertyName 'AppStderrCreationDisposition' -Value 4
Set-ServiceProperty -Name $serviceName -PropertyName 'AppRotateFiles' -Value 1
Set-ServiceProperty -Name $serviceName -PropertyName 'AppRotateOnline' -Value 1
Set-ServiceProperty -Name $serviceName -PropertyName 'AppRotateSeconds' -Value 0
Set-ServiceProperty -Name $serviceName -PropertyName 'AppRotateBytes' -Value 500000

Start-ServiceAndSetToAutoStart -Name $serviceName

Copy-ScriptsToHooksDir -ScriptPaths @(Get-ChildItem -Path "$PSScriptRoot\hooks" | ForEach-Object { $_.FullName })
Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'exthttpaccess' })

Write-Log 'exthttpaccess enabled' -Console

if ($EncodeStructuredOutput -eq $true) {
  Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}