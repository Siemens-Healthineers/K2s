# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Disables Prometheus/Grafana monitoring features for the k2s cluster.

.DESCRIPTION
The "monitoring" addons enables Prometheus/Grafana monitoring features for the k2s cluster.
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$dicomModule = "$PSScriptRoot\dicom.module.psm1"
$linuxNodeModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.node.module/linuxnode/vm/vm.module.psm1"

$dicomAddonName = 'dicom'

Import-Module $clusterModule, $infraModule, $addonsModule, $dicomModule, $linuxNodeModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Checking cluster status' -Console

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

Write-Log 'Check whether dicom addon is already disabled'

if ($null -eq (Invoke-Kubectl -Params 'get', 'namespace', $dicomAddonName, '--ignore-not-found').Output -and (Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = $dicomAddonName })) -ne $true) {
    $errMsg = "Addon $dicomAddonName is already disabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyDisabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

$dicomPathManifests = Get-DicomConfig

Write-Log 'Uninstalling ingress rules' -Console
Remove-IngressForTraefik -Addon ([pscustomobject] @{Name = $dicomAddonName })
Remove-IngressForNginx -Addon ([pscustomobject] @{Name = $dicomAddonName })

Write-Log 'Deleting main dicom addon resources ..' -Console
(Invoke-Kubectl -Params 'delete', '-k', $dicomPathManifests).Output | Write-Log

Write-Log 'Deleting persistent volumes' -Console
$dicomAttributes = Get-AddonConfig -Name $dicomAddonName
# retrieve storage usage from config
if ($dicomAttributes.StorageUsage -eq 'default') {
    $StorageUsage = 'default'
    Write-Log "Storage usage is:$StorageUsage" -Console
    $pvConfig = Get-PVConfigDefault
    (Invoke-Kubectl -Params 'delete', '--ignore-not-found=true', '-k', $pvConfig).Output | Write-Log
    # remove from master node folder /mnt/dicom with all the subdirectories
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo rm -rf /mnt/dicom').Output | Write-Log
    #(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo rmdir /mnt/dicom').Output | Write-Log
}
else {
    $StorageUsage = 'custom'
    Write-Log "Storage usage is:$StorageUsage" -Console
    $pvConfig = Get-PVConfigStorage
    (Invoke-Kubectl -Params 'delete', '--ignore-not-found=true', '-k', $pvConfig).Output | Write-Log

}

# delete namespace
(Invoke-Kubectl -Params 'delete', '--ignore-not-found=true', '-f', "$dicomPathManifests\dicom-namespace.yaml").Output | Write-Log

# remove addon from setup.json
Remove-AddonFromSetupJson -Addon ([pscustomobject] @{Name = $dicomAddonName })

# adapt other addons
Update-Addons

Write-Log 'dicom server uninstalled successfully' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}