# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Contains common methods for installing and uninstalling Metrics server for Kubernetes.
#>

function Get-MetricsServerConfig {
    return "$PSScriptRoot\manifests\metrics-server.yaml"
}