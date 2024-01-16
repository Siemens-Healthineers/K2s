@echo off
REM SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
REM SPDX-License-Identifier: MIT
@echo on
@rem wrapper for powershell script with same name
@SET installationDirectory=%~dp0..
@"%installationDirectory%\k2s" stop %*