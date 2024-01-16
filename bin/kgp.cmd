@echo off
REM SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
REM SPDX-License-Identifier: MIT
@echo on
@kubectl.exe get pods -o wide -A %*
