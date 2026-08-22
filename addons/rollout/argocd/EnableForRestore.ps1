# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Re-enables rollout argocd during restore.

.DESCRIPTION
Restore-specific enable hook for rollout argocd.
Delegates to Enable.ps1 but skips Update.ps1 there, so update runs only once
at the end of Restore.ps1 after backup content import.

.PARAMETER BackupDir
Directory containing backup.json (passed by CLI restore flow, currently unused).

.EXAMPLE
powershell <installation folder>\addons\rollout\argocd\EnableForRestore.ps1 -BackupDir C:\Temp\rollout-argocd-restore
#>

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing backup.json (passed by CLI restore flow)')]
    [string] $BackupDir,

    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,

    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,

    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$infraModule = "$PSScriptRoot/../../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
Import-Module $infraModule

Initialize-Logging -ShowLogs:$ShowLogs
Write-Log '[AddonRestore] Delegating to rollout argocd Enable.ps1 with SkipPostEnableUpdate=true' -Console

$enableScript = Join-Path $PSScriptRoot 'Enable.ps1'
& $enableScript -ShowLogs:$ShowLogs -EncodeStructuredOutput:$EncodeStructuredOutput.IsPresent -MessageType $MessageType -SkipPostEnableUpdate
