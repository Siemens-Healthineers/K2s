# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

$pathModule = "$PSScriptRoot\..\path\path.module.psm1"

Import-Module $pathModule

$kubePath = Get-KubePath
$hookDir = "$kubePath\LocalHooks"

function Invoke-Hook {
    param (
        [parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $HookName = $(throw 'Please specify the hook to be executed.'),
        [parameter()]
        [string] $AdditionalHooksDir = ''
    )
    $hooksFilter = "*$HookName.ps1"

    Write-Log "Executing hooks with hook name '$HookName'.."

    $executionCount = 0

    Get-ChildItem -Path $hookDir -Filter $hooksFilter -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Log "  Executing '$($_.FullName)'.."
        & "$($_.FullName)"
        $executionCount++
    }

    if ($AdditionalHooksDir -ne '') {
        Get-ChildItem -Path $AdditionalHooksDir -Filter $hooksFilter -Force -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Log "  Executing '$($_.FullName)'.."
            & "$($_.FullName)"
            $executionCount++
        }
    }

    if ($executionCount -eq 0) {
        Write-Log "No '$HookName' hooks found."
    }
}

Export-ModuleMember Invoke-Hook