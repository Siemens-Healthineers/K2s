# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Contains common methods for installing and uninstalling ingress-nginx
#>

function Get-IngressNginxConfig {
    return "$PSScriptRoot\manifests\ingress-nginx.yaml"
}