# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Enables dicom server for the k2s cluster.

.DESCRIPTION
The "dicom" addons enables dicom server for the k2s cluster.

#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [ValidateSet('nginx', 'traefik', 'none')]
    [string] $Ingress = 'none',
    [ValidateSet('smb', 'none')]
    [string] $Storage = 'none',    
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$dicomModule = "$PSScriptRoot\dicom.module.psm1"
$viewerModule = "$PSScriptRoot\..\viewer\viewer.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule, $dicomModule, $viewerModule

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

$setupInfo = Get-SetupInfo
if ($setupInfo.Name -ne 'k2s') {
    $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon $addonName can only be enabled for 'k2s' setup type."  
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = $addonName })) -eq $true) {
    $errMsg = "Addon $addonName is already enabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

if ($Ingress -ne 'none') {
    Enable-IngressAddon -Ingress:$Ingress
}

if ($Storage -ne 'none') {
    Enable-StorageAddon -Storage:$Storage
}

$dicomConfig = Get-DicomConfig
(Invoke-Kubectl -Params 'apply', '-f', "$dicomConfig\dicom-namespace.yaml").Output | Write-Log

Write-Log 'Determine storage setup' -Console
$StorageUsage = 'default'
if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'storage' })) -eq $true) {
    if ($Storage -ne 'none') {
        $pvConfig = Get-PVConfigStorage
        (Invoke-Kubectl -Params 'apply' , '-k', $pvConfig).Output | Write-Log
        $StorageUsage = 'storage'
        Write-Log 'Use storage addon for storing DICOM data' -C
    }
    else {
        $answer = Read-Host 'Addon storage is enabled. Would you like to reuse the storage provided by that addon for the DICOM data ? (y/N)'
        if ($answer -ne 'y') {
            $pvConfig = Get-PVConfigDefault
            (Invoke-Kubectl -Params 'apply' , '-k', $pvConfig).Output | Write-Log
            Write-Log 'Use default storage for DICOM data' -Console
        }
        else {
            $pvConfig = Get-PVConfigStorage
            (Invoke-Kubectl -Params 'apply' , '-k', $pvConfig).Output | Write-Log
            $StorageUsage = 'storage'
            Write-Log 'Use storage addon for storing DICOM data' -C
        }
    }
}
else {
    $pvConfig = Get-PVConfigDefault
    (Invoke-Kubectl -Params 'apply' , '-k', $pvConfig).Output | Write-Log
    Write-Log 'Use default storage for DICOM data' -Console
}

Write-Log 'Installing dicom server and client..' -Console
(Invoke-Kubectl -Params 'apply' , '-k', $dicomConfig).Output | Write-Log

Write-Log 'Checking dicom addon status' -Console
Write-Log 'Waiting for Pods..'
$kubectlCmd = (Invoke-Kubectl -Params 'rollout', 'status', 'deployments', '-n', 'dicom', '--timeout=180s')
Write-Log $kubectlCmd.Output
if (!$kubectlCmd.Success) {
    $errMsg = 'dicom server could not be deployed!'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}
$kubectlCmd = (Invoke-Kubectl -Params 'rollout', 'status', 'statefulsets', '-n', 'dicom', '--timeout=180s')
Write-Log $kubectlCmd.Output
if (!$kubectlCmd.Success) {
    $errMsg = 'dicom server could not be deployed!'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}
$kubectlCmd = (Invoke-Kubectl -Params 'rollout', 'status', 'daemonsets', '-n', 'dicom', '--timeout=180s')
Write-Log $kubectlCmd.Output
if (!$kubectlCmd.Success) {
    $errMsg = 'dicom server could not be deployed!'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = $addonName; StorageUsage = $StorageUsage })

&"$PSScriptRoot\Update.ps1"

# adapt other addons
Update-Addons -AddonName $addonName

Write-Log 'dicom server installed successfully'

Write-UsageForUser

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}