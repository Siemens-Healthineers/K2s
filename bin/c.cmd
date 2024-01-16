@echo off
REM SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
REM SPDX-License-Identifier: MIT
@echo on
@SET installationDirectory=%~dp0..
@"%installationDirectory%\bin\crictl.exe" %*

