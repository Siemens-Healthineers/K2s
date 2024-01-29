# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

Import-Module "$PSScriptRoot\..\..\..\..\..\smallsetup\status\RunningState.module.psm1" -Prefix legacy

function Get-RunningState {
    param(
        [Parameter(Mandatory = $false)]
        [string]
        $SetupName = $(throw 'SetupName not specified')
    )
    return Get-legacyRunningState -SetupType:$SetupName
}