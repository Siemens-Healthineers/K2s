# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

function Get-FluxConfig {
    return "$PSScriptRoot\manifests\flux-system"
}

Export-ModuleMember -Function Get-FluxConfig
