# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Disables Ceph CSI storage provisioner addon

.DESCRIPTION
Removes Ceph CSI operator components and optionally removes PersistentVolumes.

.PARAMETER ShowLogs
If log output shall be streamed also to CLI output.

.PARAMETER Force
Delete all PersistentVolumes when disabling (data loss)

.PARAMETER Keep
Keep all PersistentVolumes when disabling (data preserved)
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Delete all PersistentVolumes (data loss)')]
    [switch] $Force = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Keep all PersistentVolumes (data preserved)')]
    [switch] $Keep = $false,
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceding parameters')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$infraModule = "$PSScriptRoot/../../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"
$validationModule = "$PSScriptRoot\..\storage-validation.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule, $validationModule
Initialize-Logging -ShowLogs:$ShowLogs
Write-Log 'Checking cluster status' -Console
# get addon name from folder path
$addonName = Get-AddonNameFromFolderPath -BaseFolderPath $PSScriptRoot

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }
    Write-Log $systemError.Message -Error
    exit 1
}

Write-Log 'Check whether storage ceph addon is already disabled'
if ($null -eq (Invoke-Kubectl -Params 'get', 'namespace', 'ceph-csi-operator-system', '--ignore-not-found').Output -and (Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'storage'; Implementation = 'ceph' })) -ne $true) {
    $errMsg = "Addon 'storage ceph' is already disabled, nothing to do."
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyDisabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Uninstalling storage ceph' -Console

$CrdsDirectory = "$PSScriptRoot\manifests\crds"
(Invoke-Kubectl -Params 'delete', '-f', $CrdsDirectory).Output | Write-Log

$cephStorageYamlDir = "$PSScriptRoot\manifests"
(Invoke-Kubectl -Params 'delete', '-k', $cephStorageYamlDir, '--ignore-not-found').Output | Write-Log

(Invoke-Kubectl -Params 'delete', 'namespace', 'ceph-csi-operator-system', '--ignore-not-found').Output | Write-Log

(Invoke-Kubectl -Params 'delete', 'namespace', 'ceph-csi-cephfs', '--ignore-not-found').Output | Write-Log

$gatewayApiCrds = "$PSScriptRoot\common\manifests\crds\crd.yaml"
(Invoke-Kubectl -Params 'delete', '--ignore-not-found', '--timeout=30s', '-f', $gatewayApiCrds).Output | Write-Log

# Mark Ceph as disabled in registry
Update-StorageImplementationRegistry -Implementation 'ceph' -Enabled $false

Write-Log "[Ceph] Addon disabled successfully" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{
        Error = $null
        Status = "Storage ceph addon disabled successfully"
        AddonName = $addonName
        DataAction = if ($Force) { "deleted" } elseif ($Keep) { "preserved" } else { "prompted" }
    }
}
