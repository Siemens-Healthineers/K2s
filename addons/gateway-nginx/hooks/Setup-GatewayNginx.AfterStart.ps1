# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Post-start hook to re-establish nginx gateway fabric.

.DESCRIPTION
Post-start hook to re-establish nginx gateway fabric.
#>

Import-Module "$PSScriptRoot\..\..\smallsetup\ps-modules\log\log.module.psm1"

kubectl delete pods --all -n nginx-gateway

Write-Log 'nginx gateway fabric re-established after cluster start.' -Console