# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

# ImportImage.ps1

<#
.Description
Import image from oci tar archive
#>

Param (
    [parameter(Mandatory = $false)]
    [string] $ImagePath,
    [parameter(Mandatory = $false)]
    [string] $ImageDir,
    [parameter(Mandatory = $false)]
    [switch] $Windows = $false,
    [parameter(Mandatory = $false)]
    [switch] $DockerArchive = $false,
    [parameter(Mandatory = $false)]
    [switch] $ShowLogs = $false
)

# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\..\common\GlobalFunctions.ps1

$setupInfoModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.cluster.module\setupinfo\setupinfo.module.psm1"
$statusModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.cluster.module\status\status.module.psm1"
$imageFunctionsModule = "$PSScriptRoot\ImageFunctions.module.psm1"
$loggingModule = "$PSScriptRoot\..\ps-modules\log\log.module.psm1"
Import-Module $setupInfoModule, $imageFunctionsModule, $loggingModule, $statusModule -DisableNameChecking
Initialize-Logging -ShowLogs:$ShowLogs

$systemError = Test-SystemAvailability
if ($systemError) {
    throw $systemError
}

$images = @()
if ($ImagePath -ne '') {
    $images += $ImagePath
    Write-Output "Importing image $ImagePath. This can take some time..."
}
elseif ($ImageDir -ne '') {
    $files = Get-Childitem -recurse $ImageDir | Where-Object { $_.Name -match '.*.tar' } | ForEach-Object { $_.Fullname }
    $images += $files
    Write-Log "Importing images from $ImageDir. This can take some time..."
}

if ($Windows) {
    $setupInfo = Get-SetupInfo

    if ($setupInfo.LinuxOnly) {
        throw 'Cannot import windows image, linux-only setup is installed'
    }

    if ($setupInfo.Name -eq $global:SetupType_MultiVMK8s) {
        $tmpPath = 'C:\\temp\\tmp.tar'
        $session = Open-RemoteSessionViaSSHKey $global:Admin_WinNode $global:WindowsVMKey
        foreach ($image in $images) {
            scp.exe -r -q -o StrictHostKeyChecking=no -i $global:WindowsVMKey "$image" "${global:Admin_WinNode}:$tmpPath" 2>&1 | % { "$_" }

            Invoke-Command -Session $session {
                Set-Location "$env:SystemDrive\k"
                Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

                # load global settings
                &$env:SystemDrive\k\smallsetup\common\GlobalVariables.ps1

                &$global:NerdctlExe -n k8s.io load -i $using:tmpPath
            }
        }
    }
    else {
        foreach ($image in $images) {
            &$global:NerdctlExe -n k8s.io load -i $image
            if ($?) {
                Write-Log "$image imported successfully"
            }
        }
    }
}
else {
    foreach ($image in $images) {
        Copy-FromToMaster $image $($global:Remote_Master + ':' + '/tmp/import.tar')

        if (!$?) {
            Write-Error "Image $image could not be copied to KubeMaster"
        }

        if (!$DockerArchive) {
            ExecCmdMaster 'sudo buildah pull oci-archive:/tmp/import.tar 2>&1' -NoLog
        }
        else {
            ExecCmdMaster 'sudo buildah pull docker-archive:/tmp/import.tar 2>&1' -NoLog
        }

        if ($?) {
            Write-Log "Image archive $image imported successfully."
        }

        ExecCmdMaster 'cd /tmp && sudo rm -rf import.tar' -NoLog
    }
}