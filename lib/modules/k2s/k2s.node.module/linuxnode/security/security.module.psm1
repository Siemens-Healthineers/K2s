# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$infraModule = "$PSScriptRoot\..\..\..\k2s.infra.module\k2s.infra.module.psm1"
$vmModule = "$PSScriptRoot\..\vm\vm.module.psm1"
Import-Module $infraModule, $vmModule

$sshKeyControlPlane = Get-SSHKeyControlPlane
$sshConfigDir = Get-SshConfigDir


function New-SshKey {
    param (
        [string]$IpAddress = $(throw "Argument missing: IpAddress")
    )
    # remove previous VM key from known hosts
    $file = $sshConfigDir + '\known_hosts'
    if (Test-Path $file) {
        Write-Log 'Remove previous VM key from known_hosts file'

        ssh-keygen.exe -R $IpAddress 2>&1 | % { "$_" }
    }


    # Create SSH keypair, if not yet available
    $sshDir = Split-Path -parent $sshKeyControlPlane
    if (!(Test-Path $sshDir)) {
        mkdir $sshDir | Out-Null
    }
    if (!(Test-Path $sshKeyControlPlane)) {
        Write-Log "creating SSH key $sshKeyControlPlane"
        if ($PSVersionTable.PSVersion.Major -gt 5) {
            echo y | ssh-keygen.exe -t rsa -b 2048 -f $sshKeyControlPlane -N ''
        }
        else {
            echo y | ssh-keygen.exe -t rsa -b 2048 -f $sshKeyControlPlane -N '""'  # strange powershell syntax for empty passphrase...
        }
    }
    if (!(Test-Path $sshKeyControlPlane)) {
        throw "unable to generate SSH keys ($sshKeyControlPlane)"
    }
    return "$sshKeyControlPlane.pub"
}

function Remove-SshKey {
    param (
        [string]$IpAddress = $(throw "Argument missing: IpAddress")
    )
    Write-Log 'Remove control plane ssh keys from host'
    ssh-keygen.exe -R $IpAddress 2>&1 | % { "$_" } | Out-Null
    Remove-Item -Path ($sshConfigDir + '\kubemaster') -Force -Recurse -ErrorAction SilentlyContinue
}

function Copy-LocalPublicSshKeyToRemoteComputer {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$UserName = $(throw "Argument missing: UserName"),
        [string]$UserPwd = $(throw "Argument missing: UserPwd"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw "Argument missing: IpAddress")
    )

    $user = "$UserName@$IpAddress"
    $userPwd = $UserPwd

    $localSourcePath = "$sshKeyControlPlane.pub"
    $publicKeyFileName = Split-Path -Path $localSourcePath -Leaf
    $targetPath = "/tmp/$publicKeyFileName"
    $remoteTargetPath = "$targetPath"
    Copy-ToControlPlaneViaUserAndPwd -Source $localSourcePath -Target $remoteTargetPath
    (Invoke-CmdOnControlPlaneViaUserAndPwd "sudo mkdir -p ~/.ssh" -RemoteUser "$user" -RemoteUserPwd "$userPwd").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaUserAndPwd "sudo cat $targetPath | sudo tee ~/.ssh/authorized_keys" -RemoteUser "$user" -RemoteUserPwd "$userPwd").Output | Write-Log
}

function Remove-ControlPlaneAccessViaUserAndPwd {
    # remove password for remote user and disable password login
    (Invoke-CmdOnControlPlaneViaSSHKey 'sudo passwd -d remote').Output | Write-Log

    (Invoke-CmdOnControlPlaneViaSSHKey "sudo sed -i 's/.*NAutoVTs.*/NAutoVTs=0/' /etc/systemd/logind.conf").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey "sudo sed -i 's/.*ReserveVT.*/ReserveVT=0/' /etc/systemd/logind.conf").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey 'sudo systemctl disable getty@tty1.service 2>&1').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey 'sudo systemctl stop "getty@tty*.service"').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey 'sudo systemctl restart systemd-logind.service').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey 'echo Include /etc/ssh/sshd_config.d/*.conf | sudo tee -a /etc/ssh/sshd_config').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey 'sudo touch /etc/ssh/sshd_config.d/disable_pwd_login.conf').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey 'echo ChallengeResponseAuthentication no | sudo tee -a /etc/ssh/sshd_config.d/disable_pwd_login.conf').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey 'echo PasswordAuthentication no | sudo tee -a /etc/ssh/sshd_config.d/disable_pwd_login.conf').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey 'echo UsePAM no | sudo tee -a /etc/ssh/sshd_config.d/disable_pwd_login.conf').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey 'echo PermitRootLogin no | sudo tee -a /etc/ssh/sshd_config.d/disable_pwd_login.conf').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey 'sudo systemctl reload ssh').Output | Write-Log
}

Export-ModuleMember New-SshKey, Remove-SshKey, Copy-LocalPublicSshKeyToRemoteComputer, Remove-ControlPlaneAccessViaUserAndPwd