# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#[
.SYNOPSIS
Backs up autoscaling (KEDA) configuration/resources

.DESCRIPTION
Exports selected Kubernetes resources of the autoscaling addon into a staging folder.
The CLI wraps the staging folder into a zip archive.

.PARAMETER BackupDir
Destination directory for backup artifacts.

.EXAMPLE
powershell <installation folder>\addons\autoscaling\Backup.ps1 -BackupDir C:\Temp\autoscaling-backup
#>
Param(
    [parameter(Mandatory = $true, HelpMessage = 'Directory where backup files will be written')]
    [string] $BackupDir,

    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,

    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,

    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule

Initialize-Logging -ShowLogs:$ShowLogs

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{ Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

Write-Log "[AddonBackup] Backing up addon 'autoscaling'" -Console

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{ Name = 'autoscaling' })) -ne $true) {
    $errMsg = "Addon 'autoscaling' is not enabled. Enable it before running backup."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-not-enabled' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$namespace = 'autoscaling'
$nsCheck = Invoke-Kubectl -Params 'get', 'ns', $namespace
if (-not $nsCheck.Success) {
    $errMsg = "Namespace '$namespace' not found. Is addon 'autoscaling' installed? Details: $($nsCheck.Output)"

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'namespace-not-found' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null

$files = @()

try {
    # Always back up the namespace object (guarantees a non-empty file list)
    $nsPath = Join-Path $BackupDir 'autoscaling-namespace.yaml'
    $nsResult = Invoke-Kubectl -Params 'get', 'ns', $namespace, '-o', 'yaml'
    if (-not $nsResult.Success) {
        throw "Failed to export Namespace '$namespace': $($nsResult.Output)"
    }
    $nsResult.Output | Set-Content -Path $nsPath -Encoding UTF8 -Force
    $files += (Split-Path -Leaf $nsPath)

    # Back up ConfigMaps in the autoscaling namespace, excluding auto-generated kube-root-ca.crt
    $cmList = Invoke-Kubectl -Params 'get', 'configmap', '-n', $namespace, '-o', 'name'
    if (-not $cmList.Success) {
        throw "Failed to list ConfigMaps in namespace '$namespace': $($cmList.Output)"
    }

    $cmNames = @($cmList.Output -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($cm in $cmNames) {
        if ($cm -eq 'configmap/kube-root-ca.crt') {
            continue
        }

        $nameOnly = ($cm -split '/')[1]
        $cmPath = Join-Path $BackupDir ("configmap_{0}.yaml" -f $nameOnly)

        $cmResult = Invoke-Kubectl -Params 'get', 'configmap', $nameOnly, '-n', $namespace, '-o', 'yaml'
        if (-not $cmResult.Success) {
            throw "Failed to export ConfigMap '$nameOnly': $($cmResult.Output)"
        }

        $cmResult.Output | Set-Content -Path $cmPath -Encoding UTF8 -Force
        $files += (Split-Path -Leaf $cmPath)
    }
}
catch {
    $errMsg = "Backup of addon 'autoscaling' failed: $($_.Exception.Message)"

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-backup-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$version = 'unknown'
try {
    $version = Get-ConfigProductVersion
}
catch {
    # best-effort only
}

$manifest = [pscustomobject]@{
    k2sVersion = $version
    addon      = 'autoscaling'
    files      = $files
    createdAt  = (Get-Date).ToString('o')
}

$manifestPath = Join-Path $BackupDir 'backup.json'
$manifest | ConvertTo-Json -Depth 20 | Set-Content -Path $manifestPath -Encoding UTF8 -Force

Write-Log "[AddonBackup] Wrote $($files.Count) files to '$BackupDir'" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
