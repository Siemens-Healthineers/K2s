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

$k8sApiModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k8s-api/k8s-api.module.psm1"
# TODO: import log module again after migration has been finished

Import-Module $k8sApiModule

Invoke-Kubectl -Params 'delete', 'pods', '--all', '-n', 'gateway-api' | Out-Null

Write-Log 'nginx gateway fabric re-established after cluster start' -Console