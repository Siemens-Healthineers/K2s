@echo off
REM SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
REM SPDX-License-Identifier: MIT
@echo on
@echo cleanup of all succeeded pods...
@kubectl delete pod --field-selector=status.phase==Succeeded -A
@kubectl delete pod --field-selector=status.phase==Evicted -A
