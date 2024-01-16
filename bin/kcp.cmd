@echo off
REM SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
REM SPDX-License-Identifier: MIT
@echo on
@echo cleanup of all succeeded pods...
@kubectl delete pod --field-selector=status.phase==Succeeded -A
@kubectl delete pod --field-selector=status.phase==Evicted -A
