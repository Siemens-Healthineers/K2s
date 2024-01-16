@echo off
REM SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
REM SPDX-License-Identifier: MIT
@echo on
@rem wrapper for BuildImage.ps1 script
@rem Only for backward compatibility, will be removed later. Use BuildImage.cmd instead
@SET installationDirectory=%~dp0..
@%SYSTEMROOT%\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -Command "try { & '%installationDirectory%\smallsetup\common\BuildImage.ps1' %*; $err = -not $? } catch { Write-Host $_; $err = $true; $LastExitCode = 1 }; if ($err) { $ppid = (gwmi Win32_Process -Filter processid=$pid).ParentProcessId; $cl = (gwmi Win32_Process -Filter processid=$ppid).CommandLine; if ($cl -like '*cmd.exe /c*') { $gppid = (gwmi Win32_Process -Filter processid=$ppid).ParentProcessId; $pn = (gps -id $gppid).ProcessName; if ($pn -eq 'explorer') { pause } } }; exit $LastExitCode"
