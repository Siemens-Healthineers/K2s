# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

# Imports

$pathModule = "$PSScriptRoot\..\..\k2s.infra.module\path\path.module.psm1"

Import-Module $pathModule

$script:ConsoleLogging = $false  # Enables Console logging along with file logging
$script:NestedLogging = $false   # Shall be used when we need to capture output from Invoke-Command, which enables console logging, skips file logging.

# logging
$k2sLogFilePart = ':\var\log\k2s.log'
$k2sLogFile = (Get-SystemDriveLetter) + $k2sLogFilePart

<#
.SYNOPSIS
Initialize logging module with supplied options.

.DESCRIPTION
Initialize logging module with supplied options to dictate console logging.

.PARAMETER ShowLogs
Enables console logging

.PARAMETER Nested
Enables console logging only (host->VM), should be used when Invoke-Command is used

.EXAMPLE
Initialize-Logging -ShowLogs:$true   ---------> Will log all messages to console along with file logging
Initialize-Logging -ShowLogs:$false   --------> Default behaviour, will log all messages to file and messages with -Console flag to console.
#>
function Initialize-Logging {
    param (
        [Parameter(Mandatory = $false, HelpMessage = 'Write all messages to console and log file.')]
        [switch] $ShowLogs = $false,
        [Parameter(Mandatory = $false, HelpMessage = 'Write all messages to only to console for nested case.')]
        [switch] $Nested = $false
    )
    Write-Verbose "Intializing log module with ShowLogs:$ShowLogs, Nested:$Nested"
    $script:ConsoleLogging = $ShowLogs
    $script:NestedLogging = $Nested
}

<#
.SYNOPSIS
Removes log file

.DESCRIPTION
Removes log file for fresh installation if AppendLogFile

.PARAMETER AppendLogFile
If set then log file will not deleted

.EXAMPLE
Reset-LogFile -AppendLogFile:$true
#>
function Reset-LogFile {
    param (
        [Parameter(Mandatory = $false, HelpMessage = 'Write all messages to console and log file.')]
        [switch] $AppendLogFile = $false
    )
    #cleanup old logs
    if ( -not  $AppendLogFile) {
        Remove-Item -Path $k2sLogFile -Force -Recurse -ErrorAction SilentlyContinue
    }
}


<#
.SYNOPSIS
Logs a message to the log file and output console based on supplied flags.

.DESCRIPTION
Based on input flags, passed message will be either displayed on the console, or logged to file, or both.

.PARAMETER Messages
The message

.EXAMPLE
Write-Log "Hello"                      ---------> Will write the message in log file: [30-10-2023 13:20:40] Hello
Write-Log "Hello" -Console             ---------> Will write the message in log file: [30-10-2023 13:20:40] Hello and
                                                                                      console: [10:34:53] Hello
Write-Log "Hello" -Progress            ---------> Will write the message in file with no newline
Write-Log "Hello" -Console -Progress   ---------> Will write the message in file and in console with no newline
#>
function Write-Log {
    param (
        [Parameter(Mandatory = $false, HelpMessage = 'Messages to be logged.', ValueFromPipeline = $true)]
        [string[]] $Messages,
        [Parameter(Mandatory = $false, HelpMessage = 'Write all messages to console and log file.')]
        [switch] $Console = $false,
        [Parameter(Mandatory = $false, HelpMessage = 'This is a progress message, do not append new line in the log file.')]
        [switch] $Progress = $false,
        [Parameter(Mandatory = $false, HelpMessage = 'This is a error message, add to log file and console as Write-Error.')]
        [switch] $Error = $false,
        [Parameter(Mandatory = $false, HelpMessage = 'Write messages to stdout using Write-Output (default is Write-Information)')]
        [switch] $Raw = $false,
        [Parameter(Mandatory = $false, HelpMessage = "Write ssh stdout messages to stdout using Write-Output (mark message with '#ssh#')")]
        [switch] $Ssh = $false
    )

    Begin {
        if ((Test-Path -Path $k2sLogFile) -eq $false) {
            $logDir = Split-Path -Path $k2sLogFile

            mkdir -force $logDir | Out-Null
        }
    }

    Process {

        try {
            foreach ($message in $Messages) {
                $message = $message -replace "[`n`r]", ' '
                $message = $message -replace "[`0]", ''

                if ([string]::IsNullOrWhiteSpace($message) -or ($message.Trim().Length -eq 0)) {
                    continue
                }

                $dayTimestamp = [DateTime]::Now.ToString('dd-MM-yyyy HH:mm:ss')
                $timestamp = [DateTime]::Now.ToString('HH:mm:ss')

                $consoleMessage = if (!$Progress) { "[$timestamp] $message" } else { $message }

                if ($consoleMessage -match '\[([^]]+::[^]]+)\]\s?') {
                    # module message, eg. [11:39:19] [cli-messages.module.psm1::Send-ToCli] message converted
                    # module message part [cli-messages.module.psm1::Send-ToCli] should not be logged
                    $match = ($consoleMessage | Select-String -Pattern '\[([^]]+::[^]]+)\]\s?').Matches.Value
                    $consoleMessage = $consoleMessage.Replace($match, '')
                }

                if ($script:NestedLogging) {
                    if ($Error) {
                        Write-Error -Message $consoleMessage
                    }
                    else {
                        Write-Output "[$timestamp][$env:COMPUTERNAME] $message"
                    }
                    return
                }

                $logFileMessage = if (!$Progress) { "[$dayTimestamp] $message" } else { $message }

                if ($message -match '^\[\d{2}:\d{2}:\d{2}\]\[([^]]+)\]') {
                    if ($script:ConsoleLogging) {
                        Write-Information $message -InformationAction Continue
                    }
                    $logFileMessage | Out-File -Append -FilePath $k2sLogFile -Encoding utf8
                    return
                }

                if ($Error) {
                    "[$dayTimestamp][ERROR] $message" | Out-File -Append -FilePath $k2sLogFile -Encoding utf8
                    Write-Error $consoleMessage
                }
                elseif ($Progress -and ($Console -or $script:ConsoleLogging)) {
                    Write-Host $consoleMessage -NoNewline
                    $logFileMessage | Out-File -Append -FilePath $k2sLogFile -Encoding utf8 -NoNewline
                }
                elseif ($Console -or $script:ConsoleLogging) {
                    if ($Raw) {
                        Write-Output $message
                    }
                    elseif ($Ssh) {
                        Write-Output "#ssh#$message"
                    }
                    else {
                        Write-Information $consoleMessage -InformationAction Continue
                    }
                    $logFileMessage | Out-File -Append -FilePath $k2sLogFile -Encoding utf8
                }
                else {
                    $logFileMessage | Out-File -Append -FilePath $k2sLogFile -Encoding utf8
                }
            }
        }
        catch [System.IO.DirectoryNotFoundException] {
            return
        }
    }

    End {}
}

function Get-k2sLogDirectory {
    $logsDir = Split-Path -Path $k2sLogFile -Parent
    return $logsDir
}

function Get-LogFilePath {
    return $k2sLogFile 
}

function Get-LogFilePathPart {
    return $k2sLogFilePart 
}

function Save-k2sLogDirectory {
    param (
        [Parameter(Mandatory = $false, HelpMessage = 'Remove var folder after saving logs')]
        [switch] $RemoveVar = $false
    )

    if (!(Test-Path "$env:TEMP")) {
        New-Item -Path "$env:TEMP" -ItemType Directory | Out-Null
    }

    $destinationFolder = "$env:TEMP\k2s_log_$(get-date -f yyyyMMdd_HHmmss)"
    Copy-Item -Path 'C:\var\log' -Destination $destinationFolder -Force -Recurse
    Compress-Archive -Path $destinationFolder -DestinationPath "$destinationFolder.zip" -CompressionLevel Optimal -Force
    Remove-Item -Path "$destinationFolder" -Force -Recurse -ErrorAction SilentlyContinue

    Write-Log "Logs backed up in $destinationFolder.zip" -Console

    if ($RemoveVar) {
        # the directory '<system drive>:\var' must be deleted (regardless of the installation drive) since
        # kubelet.exe writes hardcoded to '<system drive>:\var\lib\kubelet\device-plugins' (see '\pkg\kubelet\cm\devicemanager\manager.go' under https://github.com/kubernetes/kubernetes.git)
        $systemDriveLetter = (Get-Item $env:SystemDrive).PSDrive.Name
        Remove-Item -Path "$($systemDriveLetter):\var" -Force -Recurse -ErrorAction SilentlyContinue
        if ($(Get-SystemDriveLetter) -ne "$systemDriveLetter") {
            Remove-Item -Path "$(Get-SystemDriveLetter):\var" -Force -Recurse -ErrorAction SilentlyContinue
        }
    }
}

Export-ModuleMember -Variable k2sLogFilePart, k2sLogFile
Export-ModuleMember -Function Initialize-Logging, Write-Log, Reset-LogFile, Get-k2sLogDirectory, Save-k2sLogDirectory, Get-LogFilePath, Get-LogFilePathPart