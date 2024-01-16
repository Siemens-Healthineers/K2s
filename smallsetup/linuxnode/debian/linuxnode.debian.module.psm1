# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

. "$PSScriptRoot\..\..\common\GlobalFunctions.ps1"

$validationModule = "$global:KubernetesPath\lib\modules\k2s\k2s.infra.module\validation\validation.module.psm1"
Import-Module $validationModule

<#
.SYNOPSIS
Sets up the computer with Debian OS before it gets provisioned.
.DESCRIPTION
During the set-up the following is done:
- disable cloud-init.
- update grub.
- disable package validation date check to avoid "Release file expired" problem.
.PARAMETER UserName
The user name to log in.
.PARAMETER UserPwd
The password to use to log in.
.PARAMETER IpAddress
The IP address of the computer.
#>
Function Set-UpComputerWithSpecificOsBeforeProvisioning {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$UserName = $(throw "Argument missing: UserName"),
        [string]$UserPwd = $(throw "Argument missing: UserPwd"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw "Argument missing: IpAddress")
    )
    $user = "$UserName@$IpAddress"
    $userPwd = $UserPwd

    $executeRemoteCommand = { 
        param(
            $command = $(throw "Argument missing: Command"), 
            [switch]$IgnoreErrors = $false
            ) 
        if ($IgnoreErrors) {
            ExecCmdMaster -CmdToExecute $command -RemoteUser "$user" -RemoteUserPwd "$userPwd" -UsePwd -IgnoreErrors
        } else {
            ExecCmdMaster -CmdToExecute $command -RemoteUser "$user" -RemoteUserPwd "$userPwd" -UsePwd
        }
    }

    Write-Log "Check that a remote connection to the VM is possible"
    Wait-ForSSHConnectionToLinuxVMViaPwd -RemoteUser "$user" -RemoteUserPwd "$userPwd"

    &$executeRemoteCommand "sudo touch /etc/cloud/cloud-init.disabled" 
    &$executeRemoteCommand "sudo update-grub" -IgnoreErrors

    Write-Log "Disable release file validity check"
    if ($PSVersionTable.PSVersion.Major -gt 5) {
        &$executeRemoteCommand 'echo Acquire::Check-Valid-Until \"false\"\; | sudo tee /etc/apt/apt.conf.d/00snapshot' 
    } else {
        &$executeRemoteCommand 'echo Acquire::Check-Valid-Until \\\"false\\\"\; | sudo tee /etc/apt/apt.conf.d/00snapshot' 
    }

    &$executeRemoteCommand 'echo Acquire::Max-FutureTime 86400\; | sudo tee -a /etc/apt/apt.conf.d/00snapshot' 
}

<#
.SYNOPSIS
Sets up the computer with Debian OS after it gets provisioned.
.DESCRIPTION
During the set-up the following is done:
- clean up cloud-init logs and artifacts.
.PARAMETER UserName
The user name to log in.
.PARAMETER UserPwd
The password to use to log in.
.PARAMETER IpAddress
The IP address of the computer.
#>
Function Set-UpComputerWithSpecificOsAfterProvisioning {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$UserName = $(throw "Argument missing: UserName"),
        [string]$UserPwd = $(throw "Argument missing: UserPwd"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw "Argument missing: IpAddress")
    )
    $user = "$UserName@$IpAddress"
    $userPwd = $UserPwd

    ExecCmdMaster -CmdToExecute "sudo cloud-init clean" -RemoteUser "$user" -RemoteUserPwd "$userPwd" -UsePwd
}

Export-ModuleMember -Function Set-UpComputerWithSpecificOsBeforeProvisioning, Set-UpComputerWithSpecificOsAfterProvisioning
