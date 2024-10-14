@echo off
REM SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
REM SPDX-License-Identifier: MIT
@echo on
@SET installationDirectory=%~dp0..
@"%installationDirectory%\bin\crictl.exe" %*

