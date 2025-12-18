# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Contains common methods for installing and uninstalling nginx-gateway
#>
function Get-ExternalDnsConfigDir {
    return "$PSScriptRoot\..\..\common\manifests\external-dns"
}

function Get-NginxGatewayYamlDir {
    return "$PSScriptRoot\manifests"
}

function Get-NginxGatewayCrdsDir {
    return "$PSScriptRoot\manifests\crds"
}