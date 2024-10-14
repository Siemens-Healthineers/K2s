# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
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
    $hook = "$hookDir\\$HookName.ps1"
    if (Test-Path $hook) {
        &$hook
    }

    if ($AdditionalHooksDir -ne '') {
        $additionalHook = "$AdditionalHooksDir\\$HookName.ps1"
        if (Test-Path $additionalHook) {
            &$additionalHook
        }
    }
}

Export-ModuleMember Invoke-Hook