# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Contains common methods for installing and uninstalling Traefik Ingress Controller in Kubernetes.
#>

function Get-TraefikYamlDir {
    return "$PSScriptRoot\manifests"
}