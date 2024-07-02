# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
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

function Get-ExternalDnsConfigDir {
    return "$PSScriptRoot\..\common\manifests\external-dns"
}