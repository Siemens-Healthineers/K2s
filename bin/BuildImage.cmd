@echo off
REM SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
REM SPDX-License-Identifier: MIT
@echo on
@rem wrapper for powershell script with same name
@SET installationDirectory=%~dp0..
@%SYSTEMROOT%\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -Command "try { & '%installationDirectory%\smallsetup\common\%~n0.ps1' %*; $err = -not $? } catch { Write-Host $_; $err = $true; $LastExitCode = 1 }; if ($err) { $ppid = (gwmi Win32_Process -Filter processid=$pid).ParentProcessId; $cl = (gwmi Win32_Process -Filter processid=$ppid).CommandLine; if ($cl -like '*cmd.exe /c*') { $gppid = (gwmi Win32_Process -Filter processid=$ppid).ParentProcessId; $pn = (gps -id $gppid).ProcessName; if ($pn -eq 'explorer') { pause } } }; exit $LastExitCode"
