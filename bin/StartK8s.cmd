@echo off
REM SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
REM SPDX-License-Identifier: MIT
@echo on
@rem wrapper for powershell script with same name
@SET installationDirectory=%~dp0..
@"%installationDirectory%\k2s" start %*
