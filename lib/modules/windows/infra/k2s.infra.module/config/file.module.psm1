# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

function Get-JsonContent {
    param (
        [string]$FilePath
    )
    if (-Not (Test-Path $FilePath)) {
        Write-Log "The file '$FilePath' does not exist."
        return $null
    }
    return Get-Content -Path $FilePath | ConvertFrom-Json
}

function Save-JsonContent {
    param (
        [object]$JsonObject,
        [string]$FilePath
    )
    $JsonObject | ConvertTo-Json -Depth 32 | Set-Content -Path $FilePath
}

Export-ModuleMember -Function Get-JsonContent,
Save-JsonContent