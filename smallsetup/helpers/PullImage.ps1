# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

<#
.Description
Pull container images in K2s
#>

Param (
    [parameter(Mandatory = $true, HelpMessage = 'Name of the image to be pulled.')]
    [string] $ImageName,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, the image will be pulled for windows 10 node.')]
    [switch] $Windows,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)

# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\..\common\GlobalFunctions.ps1

$setupInfoModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.cluster.module\setupinfo\setupinfo.module.psm1"
Import-Module $setupInfoModule -DisableNameChecking

if (!$Windows) {
    ExecCmdMaster "sudo buildah pull $ImageName 2>&1" -Retries 5 -NoLog
}
else {
    $setupInfo = Get-SetupInfo
    if ($setupInfo.Name -ne "$global:SetupType_MultiVMK8s") {
        $retries = 5
        $success = $false
        while ($retries -gt 0) {
            $retries--
            crictl pull $ImageName

            if ($?) {
                $success = $true
                break
            }
            Start-Sleep 1
        }

        if (!$success) {
            throw "Error pulling image '$ImageName'"
        }
    }
    elseif ($setupInfo.Name -eq "$global:SetupType_MultiVMK8s") {
        if (!$setupInfo.LinuxOnly) {
            $retries = 5
            $success = $false
            while ($retries -gt 0) {
                $retries--
                ssh.exe -o StrictHostKeyChecking=no -i $global:WindowsVMKey $global:Admin_WinNode crictl pull $ImageName

                if ($?) {
                    $success = $true
                    break
                }
                Start-Sleep 1
            }

            if (!$success) {
                throw "Error pulling image $ImageName"
            }
        }
        else {
            Write-Log 'Windows image pull option is not possible for a LinuxOnly setup.' -Console
        }
    }
}