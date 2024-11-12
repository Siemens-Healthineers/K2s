@echo off
REM SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
REM SPDX-License-Identifier: MIT
@echo on
@echo removing pod %*
@kubectl delete pod %* --force

