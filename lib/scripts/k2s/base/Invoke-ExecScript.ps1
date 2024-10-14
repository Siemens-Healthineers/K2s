# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Wrapper script which acts as entrypoint for script execution

.DESCRIPTION
Wrapper script enables output formatting which is a common glue code for all high-level scripts (install, start, stop,..)

.PARAMETER Script
The high level script with all required parameters
e.g."C:\ws\k\smallsetup\StopK8s.ps1"

.EXAMPLE
No parameter
&C:\ws\k\lib\scripts\k2s\base\Invoke-ExecScript.ps1 -Script "C:\ws\k\smallsetup\StopK8s.ps1"

One or more parameters passed
&C:\ws\k\lib\scripts\k2s\base\Invoke-ExecScript.ps1 -Script "C:\ws\k\smallsetup\InstallK8s.ps1 -MasterVMProcessorCount 6 -MasterVMMemory 6GB -MasterDiskSize 50GB -ShowLogs -DeleteFilesForOfflineInstallation"
#>

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Script to be executed along with parameters')]
    [string] $Script
)

$logModule = "$PSScriptRoot/../../../../smallsetup/ps-modules/log/log.module.psm1"

Import-Module $logModule

if ($Script.Contains("-ShowLogs")) {
    Initialize-Logging -ShowLogs:$true
}

#Set-PSDebug -Trace 1

& {
    Invoke-Expression $Script
} *>&1 | ForEach-Object {
    if ($_ -is [System.Management.Automation.ErrorRecord] -and -not($_ -match "^\[\d{2}:\d{2}:\d{2}\]")) {
        # if an error occurs during install stop installation immediately
        if ($Script -match ".*\\Install.*\.ps1") {
            Write-Log $($_ | Out-String) -Error
            Write-Log "Installation failed!"
            exit
        }
        # ignore errors when uninstalling/resetting cluster
        if (($Script -notmatch ".*\\Uninstall.*\.ps1") -and ($Script -notmatch ".*\\Reset-System.*\.ps1")) {
            Write-Log $($_ | Out-String) -Error
        }
    } elseif($_ -match "^\[\d{2}:\d{2}:\d{2}\]\[([^]]+)\]") {
        # Nested message, eg. [11:39:19][WINNODE] Hello
        # Should be logged to console and file
        Write-Log $_
    } elseif($_ -match "^\[\d{2}:\d{2}:\d{2}\]") {
        # As *>&1 captures our console message from Write-Log, we need to output normally here
        Write-Information $_ -InformationAction Continue
    } elseif ($_ -match "#pm#") {
        Write-Output $_
        # Send-ToCli message
    } elseif ($_ -match "#ssh#") {
        $message = $_ -replace "#ssh#", ''
        Write-Output $message
    } else {
        # Any other message which is not captured from Write-Log or other streams, log it to console and file
        Write-Log $_
    }
}
