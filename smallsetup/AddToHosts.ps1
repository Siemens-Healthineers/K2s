# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

param([string]$DesiredIP = ''
    , [string]$Hostname = 'k2s.cluster.net'
    , [bool]$CheckHostnameOnly = $false)

# check ip
if ($DesiredIP -eq '') {
    $DesiredIP = $global:IP_Master
}

# Adds entry to the hosts file.
$hostsFilePath = "$($Env:WinDir)\system32\Drivers\etc\hosts"
$hostsFile = Get-Content $hostsFilePath

Write-Log "Add $desiredIP for $Hostname to hosts file"

$escapedHostname = [Regex]::Escape($Hostname)
$patternToMatch = If ($CheckHostnameOnly) { ".*\s+$escapedHostname.*" } Else { ".*$DesiredIP\s+$escapedHostname.*" }
If (($hostsFile) -match $patternToMatch) {
    Write-Log $desiredIP.PadRight(20, ' '), "$Hostname - not adding; already in hosts file"
}
Else {
    Write-Log $desiredIP.PadRight(20, ' '), "$Hostname - adding to hosts file... "
    Add-Content -Encoding UTF8 $hostsFilePath ("$DesiredIP".PadRight(20, ' ') + "$Hostname")
    Write-Log ' done'
}
