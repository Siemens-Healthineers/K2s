# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

&$PSScriptRoot\..\..\..\smallsetup\common\GlobalVariables.ps1
. $PSScriptRoot\..\..\..\smallsetup\common\GlobalFunctions.ps1

$k8sApiModule = "$PSScriptRoot\..\..\..\lib\modules\k2s\k2s.cluster.module\k8s-api\k8s-api.module.psm1"
$formattingModule = "$PSScriptRoot\..\..\..\lib\modules\k2s\k2s.cluster.module\k8s-api\formatting\formatting.module.psm1"

$addonsModule = "$PSScriptRoot\..\..\Addons.module.psm1"
$setupTypeModule = "$PSScriptRoot\..\..\..\smallsetup\status\SetupType.module.psm1"
$runningStateModule = "$PSScriptRoot\..\..\..\smallsetup\status\RunningState.module.psm1"


$logModule = "$PSScriptRoot\..\..\..\smallsetup\ps-modules\log\log.module.psm1"
Import-Module $addonsModule, $setupTypeModule, $runningStateModule, $k8sApiModule, $formattingModule, $logModule

$AddonName = 'smb-share'
$localHooksDir = "$PSScriptRoot\..\hooks"
$hookFileNames = 'Setup-SmbShare.AfterStart.ps1', 'Setup-SmbShare.AfterUninstall.ps1', 'Setup-SmbShare.Backup.ps1', 'Setup-SmbShare.Restore.ps1'
$hookFilePaths = $hookFileNames | ForEach-Object { return "$localHooksDir\$_" }
$logFile = "$($global:SystemDriveLetter):\var\log\ssh_smbSetup.log"
$linuxLocalPath = $global:ShareMountPointInVm
$windowsLocalPath = $global:ShareMountPoint
$linuxShareName = 'k8sshare' # exposed by Linux VM
$windowsShareName = $global:ShareSubdir # visible from VMs
$linuxHostRemotePath = "\\$global:IP_Master\$linuxShareName"
$windowsHostRemotePath = "\\$global:IP_NextHop\$windowsShareName"
$smbUserName = 'remotesmb'
$smbFullUserNameWin = "$env:computername\$smbUserName"
$smbFullUserNameLinux = "kubemaster\$smbUserName"
$smbPw = ConvertTo-SecureString $(Get-RandomPassword 25) -AsPlainText -Force
$creds = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $smbFullUserNameLinux, $smbPw
$smbCredsName = 'smbcreds'
$smbStorageClassName = 'smb'
$hostPathPatchTemplateFileName = 'template_set-host-path.patch.yaml'
$hostPathPatchFileName = 'set-host-path.patch.yaml'
$manifestBaseDir = "$PSScriptRoot\..\manifests\base"
$manifestWinDir = "$PSScriptRoot\..\manifests\windows"
$patchTemplateFilePath = "$manifestBaseDir\$hostPathPatchTemplateFileName"
$patchFilePath = "$manifestBaseDir\$hostPathPatchFileName"
$storageClassTimeoutSeconds = 600
$systemNamespace = 'kube-system'

function Test-CsiPodsCondition {
    param (
        [Parameter(Mandatory = $false)]
        [ValidateSet('Ready', 'Deleted')]
        [string]
        $Condition = 'Ready',
        [Parameter(Mandatory = $false)]
        [int]
        $TimeoutSeconds = 0 # zero returns immediately without waiting
    )
    $csiSmbLinuxNodePodCondition = Wait-ForPodCondition -Condition $Condition -Label 'app=csi-smb-node' -Namespace $systemNamespace -TimeoutSeconds $TimeoutSeconds
    if ($false -eq $csiSmbLinuxNodePodCondition) {
        return $false
    }

    $csiSmbControllerPodCondition = Wait-ForPodCondition -Condition $Condition -Label 'app=csi-smb-controller' -Namespace $systemNamespace -TimeoutSeconds $TimeoutSeconds
    if ($false -eq $csiSmbControllerPodCondition) {
        return $false
    }

    $setupType = Get-SetupType
    if ($setupType.LinuxOnly -eq $true) {
        return $true
    }

    $csiSmbWindowsNodePodCondition = Wait-ForPodCondition -Condition $Condition -Label 'app=csi-smb-node-win' -Namespace $systemNamespace -TimeoutSeconds $TimeoutSeconds
    if ($false -eq $csiSmbWindowsNodePodCondition) {
        return $false
    }

    $csiProxyPodCondition = Wait-ForPodCondition -Condition $Condition -Label 'k8s-app=csi-proxy' -Namespace $systemNamespace -TimeoutSeconds $TimeoutSeconds
    return $true -eq $csiProxyPodCondition
}

function Test-IsSmbShareWorking {
    $script:SmbShareWorking = $false
    $setupType = Get-SetupType

    if ($setupType.ValidationError) {
        throw $setupType.ValidationError
    }

    # validate setup type for SMB share as well
    if ($setupType.Name -ne $global:SetupType_k2s -and $setupType.Name -ne $global:SetupType_MultiVMK8s) {
        throw "Cannot determine if SMB share is working for invalid setup type '$($setupType.Name)'"
    }

    Test-SharedFolderMountOnWinNode

    if ($SetupType.Name -ne $global:SetupType_MultiVMK8s -or $SetupType.LinuxOnly -eq $true) {
        $script:SmbShareWorking = $script:Success -eq $true
        return
    }

    $session = Open-RemoteSessionViaSSHKey $global:Admin_WinNode $global:WindowsVMKey -NoLog

    $isWinVmSmbShareWorking = (Get-IsWinVmSmbShareWorking -Session $session)

    $script:SmbShareWorking = $script:Success -eq $true -and $isWinVmSmbShareWorking -eq $true
}

function Get-IsWinVmSmbShareWorking {
    param (
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.Runspaces.PSSession]
        $Session = $(throw 'Session not specified')
    )
    $isWinVmSmbShareWorking = Invoke-Command -Session $Session {
        Set-ExecutionPolicy Bypass -Force -ErrorAction Continue | Out-Null

        Import-Module "$env:SystemDrive\k\addons\smb-share\module\Smb-share.module.psm1" | Out-Null

        $isWorking = Test-SharedFolderMountOnWinNodeSilently

        return $isWorking
    }

    return $isWinVmSmbShareWorking
}

function Add-FirewallExceptions {
    New-NetFirewallRule -DisplayName 'K8s open port 445' -Group 'k2s' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 | Out-Null
    New-NetFirewallRule -DisplayName 'K8s open port 139' -Group 'k2s' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 139 | Out-Null
}

function Remove-FirewallExceptions {
    Remove-NetFirewallRule -DisplayName 'K8s open port 445' -ErrorAction SilentlyContinue | Out-Null
    Remove-NetFirewallRule -DisplayName 'K8s open port 139' -ErrorAction SilentlyContinue | Out-Null
}

function New-SmbHostOnWindowsIfNotExisting {
    $smb = Get-SmbShare -Name $windowsShareName -ErrorAction SilentlyContinue
    if ($smb) {
        Write-Log "SMB host '$windowsShareName' on Windows already existing, nothing to create."
        return
    }

    Write-Log "Setting up '$windowsShareName' SMB host on Windows.."

    New-LocalUser -Name $smbUserName -Password $smbPw -Description 'A k2s user account for SMB access' -ErrorAction Stop | Out-Null # Description max. length seems to be 48 chars ?!
    New-Item -Path "$global:ShareDrive\" -Name $global:ShareSubdir -ItemType 'directory' -ErrorAction SilentlyContinue | Out-Null
    New-SmbShare -Name $windowsShareName -Path $windowsLocalPath -FullAccess $smbFullUserNameWin -ErrorAction Stop | Out-Null
    Add-FirewallExceptions

    Write-Log "'$windowsShareName' SMB host set up Windows."
}

function Remove-SmbHostOnWindowsIfExisting {
    $smb = Get-SmbShare -Name $windowsShareName -ErrorAction SilentlyContinue
    if ($null -eq $smb) {
        Write-Log "SMB host '$windowsShareName' on Windows not existing, nothing to remove."
        return
    }

    Write-Log "Removing '$windowsShareName' SMB host from Windows.."

    Remove-FirewallExceptions
    Remove-SmbShare -Name $windowsShareName -Confirm:$False -ErrorAction SilentlyContinue
    Remove-Item -Force $windowsLocalPath -Recurse -Confirm:$False -ErrorAction SilentlyContinue
    Remove-LocalUser -Name $smbUserName -ErrorAction SilentlyContinue

    Write-Log "'$windowsShareName' SMB host removed from Windows."
}

function New-SmbHostOnLinuxIfNotExisting {
    # We try to access the samba share on windows side.
    # If this is not possible, we set up Samba on linux and create the shared CF - NOT the mount points yet!
    # The Samba Shared CF will be \srv\samba\k8sshare
    New-SmbGlobalMapping -RemotePath $linuxHostRemotePath -Credential $creds -UseWriteThrough $true -Persistent $true -ErrorAction SilentlyContinue

    if ((Test-Path $linuxHostRemotePath)) {
        Write-Log 'SMB host on Linux already existing, nothing to create.'
        return
    }

    Write-Log 'Setting up SMB host on Linux (Samba Share)..'

    # restart dnsmsq in order to reconnect to dnsproxy
    ExecCmdMaster 'sudo systemctl restart dnsmasq'

    # download samba and rest
    ExecCmdMaster 'sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq --yes'
    Install-DebianPackages -addon 'smb-share' -packages 'cifs-utils', 'samba'
    ExecCmdMaster "sudo adduser --no-create-home --disabled-password --disabled-login --gecos '' $smbUserName"
    ExecCmdMaster "(echo '$($creds.GetNetworkCredential().Password)'; echo '$($creds.GetNetworkCredential().Password)') | sudo smbpasswd -s -a $smbUserName" `
        -CmdLogReplacement "(echo '<password redacted>'; echo '<password redacted>') | sudo smbpasswd -s -a $smbUserName"
    ExecCmdMaster "sudo smbpasswd -e $smbUserName"
    ExecCmdMaster "sudo mkdir -p /srv/samba/$linuxShareName"
    ExecCmdMaster "sudo chown nobody:nogroup /srv/samba/$linuxShareName/"
    ExecCmdMaster "sudo chmod 0777 /srv/samba/$linuxShareName/"
    ExecCmdMaster "sudo sh -c 'echo [$linuxShareName] >> /etc/samba/smb.conf'"
    ExecCmdMaster "sudo sh -c 'echo comment = K8s share for k8s-smb-share >> /etc/samba/smb.conf'"
    ExecCmdMaster "sudo sh -c 'echo path = /srv/samba/$linuxShareName >> /etc/samba/smb.conf'"
    ExecCmdMaster "sudo sh -c 'echo browsable = yes >> /etc/samba/smb.conf'"
    ExecCmdMaster "sudo sh -c 'echo guest ok = yes >> /etc/samba/smb.conf'"
    ExecCmdMaster "sudo sh -c 'echo read only = no >> /etc/samba/smb.conf'"
    ExecCmdMaster "sudo sh -c 'echo create mask = 0777 >> /etc/samba/smb.conf'"
    ExecCmdMaster "sudo sh -c 'echo directory mask = 0777 >> /etc/samba/smb.conf'"
    ExecCmdMaster 'sudo systemctl restart smbd.service nmbd.service'

    Write-Log 'SMB host on Linux (Samba Share) set up.'
}

function Remove-SmbHostOnLinux {
    Write-Log 'Removing SMB host on Linux (Samba Share)..'

    ExecCmdMaster "sudo rm -rf /srv/samba/$linuxShareName"
    ExecCmdMaster "sudo smbpasswd -x $smbUserName"    
    ExecCmdMaster 'sudo DEBIAN_FRONTEND=noninteractive apt-get purge cifs-utils samba samba-* -qq -y'
    ExecCmdMaster 'sudo DEBIAN_FRONTEND=noninteractive apt-get autoremove -qq -y'
    ExecCmdMaster 'sudo rm -rf /var/cache/samba /run/samba /srv/samba /var/lib/samba /var/log/samba'
    ExecCmdMaster "sudo deluser --force $smbUserName"
    ExecCmdMaster 'sudo systemctl daemon-reload'

    Write-Log 'SMB host on Linux (Samba Share) removed.'
}

function Test-ForKnownSmbProblems {
    $script:HasIssues = $false

    Write-Log 'Checking known SMB problems..'
    Write-Log "Checking the setting 'access to this computer from the network'.."

    # check security settings in secedit (export security setting to be able to parse them)
    secedit /export /areas USER_RIGHTS /cfg "$env:temp\secpol_tmp.cfg" | Out-Null

    # check if local user (S-1-5-113) is in SeDenyNetworkLogonRight (Deny access to this computer from the network)
    $seDenyNetworkLogonRightOnLocalUser = (Select-String -Path "$env:temp\secpol_tmp.cfg" -Pattern 'SeDenyNetworkLogonRight') -Match 'S-1-5-113';

    # remove temp file again
    Remove-Item -force "$env:temp\secpol_tmp.cfg" -confirm:$false

    if ($seDenyNetworkLogonRightOnLocalUser) {
        Write-Log 'Local user is set in SeDenyNetworkLogonRight (Deny access to this computer from the network):'
        Write-Log "You can find the setting here: Local Security Policy (secpol.msc) -> Local Policy -> User Right Assignment -> Deny access to this computer from the network -> Here you see the 'Local account'"
        Write-Log "For this smb-setup, 'Local account' must not be there."
        Write-Log "Your 'Organizational Units (OU) Group' might be the reason for the SeDenyNetworkLogonRight - please compare your OU with the one of your colleagues"
        Write-Log 'Your OU group is...'
        gpresult /r /scope:computer | Select-String -Pattern 'OU='
        Write-Log "You can also find the setting here: 'UCMS-ControlCenter' (also called 'User-Client Info') -> 'More details...' -> 'OU' section"
        Write-Log "Please contact your administrator and let them move you to the 'R&D OU' `n"
        Write-Log "Current workaround: fix the policy issue with powershell <installation folder>\smallsetup\helpers\SetNetworkSharePolicy.ps1 `n"

        $script:HasIssues = $true
        return
    }

    Write-Log 'No known SMB issues found.'
}

function New-SharedFolderMountOnLinuxClient {
    Write-Log "Mounting '$linuxLocalPath -> $global:IP_NextHop/$windowsShareName' on Linux.."
    Remove-Item -Force -ErrorAction SilentlyContinue $logFile

    Write-Log '           Creating temporary mount script..'
    $tempFstabFile = 'fstab.tmp'
    $tempMountOnLinuxClientScript = 'tmp_mountOnLinuxClientCmd.sh'
    $mountOnLinuxClientScript = 'mountOnLinuxClientCmd.sh'
    $mountOnLinuxClientCmd = @"
        findmnt $linuxLocalPath -D >/dev/null && sudo umount $linuxLocalPath
        sudo rm -rf $linuxLocalPath
        sudo mkdir -p $linuxLocalPath
        mkdir -p ~/tmp
        cd ~/tmp
        # remove all old lines with $windowsShareName from fstab
        sed -e /k8s-smb-share/d < /etc/fstab > $tempFstabFile
        # add the new line to fstab
        echo '             Adding line for $linuxLocalPath to /etc/fstab'
        echo '//$global:IP_NextHop/$windowsShareName $linuxLocalPath cifs username=$smbUserName,password=$($creds.GetNetworkCredential().Password),rw,nobrl,soft,x-systemd.automount,file_mode=0666,dir_mode=0777,vers=3.0' >> $tempFstabFile
        sudo sh -c "cat $tempFstabFile > /etc/fstab"
        sudo rm -f $tempFstabFile
        # immediately perform the mount
        echo '             Mount $linuxLocalPath from /etc/fstab entry'
        findmnt $linuxLocalPath -D >/dev/null || sudo mount $linuxLocalPath || exit 1
        echo '             Touch $linuxLocalPath/mountedInVm.txt'
        date > $linuxLocalPath/mountedInVm.txt || exit 1
        rm ~/$mountOnLinuxClientScript
"@

    $i = 0
    while ($true) {
        $i++
        # create the bash script, with \r characters removed (for Linux)
        $tempMountScript = "$global:KubernetesPath\$tempMountOnLinuxClientScript"
        Remove-Item $tempMountScript -ErrorAction Ignore
        $mountOnLinuxClientCmd | Out-File -Encoding ascii $tempMountScript
        $target = "$global:Remote_Master" + ':/home/remote/'
        Copy-FromToMaster -Source $tempMountScript -Target $target
        Remove-Item $tempMountScript -ErrorAction Ignore

        ExecCmdMaster "sudo rm -rf ~/$mountOnLinuxClientScript"
        ExecCmdMaster "sed 's/\r//g' ~/$tempMountOnLinuxClientScript > ~/$mountOnLinuxClientScript"
        ExecCmdMaster "sudo rm -rf ~/$tempMountOnLinuxClientScript"
        ExecCmdMaster "sudo chown -R remote  /home/remote/$mountOnLinuxClientScript"
        ExecCmdMaster "sudo chmod +x /home/remote/$mountOnLinuxClientScript"

        Write-Log '           Executing script inside Linux VM as remote user...'
        ssh.exe -n '-vv' -E $logFile -o StrictHostKeyChecking=no -i $global:LinuxVMKey $global:Remote_Master "sudo su -s /bin/bash -c '~/$mountOnLinuxClientScript' remote"
        if ($LASTEXITCODE -eq 0) {
            # all ok
            break
        }
        if ($i -ge 3) {
            Test-ForKnownSmbProblems

            if ( $script:HasIssues -eq $true ) {
                Write-Log '              Executing script to fix policy issue...'
                & "$global:KubernetesPath\smallsetup\helpers\SetNetworkSharePolicy.ps1"
            }
        }
        if ($i -ge 6) {
            Test-ForKnownSmbProblems
            throw 'unable to mount shared CF in Linux machine, giving up'
        }
        Start-Sleep 2
        Write-Log '           Retry after failure...'
    }
}

function Remove-SharedFolderMountOnLinuxClient {
    Write-Log "Unmounting '$linuxLocalPath -> $global:IP_NextHop/$windowsShareName' on Linux.."
    Remove-Item -Force -ErrorAction SilentlyContinue $logFile

    Write-Log 'Creating temporary unmount script..'
    $tempFstabFile = 'fstab.tmp'
    $tempUnmountOnLinuxClientScript = 'tmp_unmountOnLinuxClientCmd.sh'
    $unmountOnLinuxClientScript = 'unmountOnLinuxClientCmd.sh'
    $unmountOnLinuxClientCmd = @"
        findmnt $linuxLocalPath -D >/dev/null && sudo umount $linuxLocalPath
        mkdir -p ~/tmp
        cd ~/tmp
        # remove all lines with $windowsShareName from fstab
        sed -e /k8s-smb-share/d < /etc/fstab > $tempFstabFile
        sudo sh -c "cat $tempFstabFile > /etc/fstab"
        sudo rm -f $tempFstabFile
        sudo systemctl daemon-reload
        sudo rm -rf $linuxLocalPath
        rm ~/$unmountOnLinuxClientScript
"@

    # create the bash script, with \r characters removed (for Linux)
    $tempUnmountScript = "$global:KubernetesPath\$tempUnmountOnLinuxClientScript"
    Remove-Item $tempUnmountScript -ErrorAction Ignore
    $unmountOnLinuxClientCmd | Out-File -Encoding ascii $tempUnmountScript
    $target = "$global:Remote_Master" + ':/home/remote/'
    Copy-FromToMaster -Source $tempUnmountScript -Target $target
    Remove-Item $tempUnmountScript -ErrorAction Ignore

    ExecCmdMaster "sudo rm -rf ~/$unmountOnLinuxClientScript"
    ExecCmdMaster "sed 's/\r//g' ~/$tempUnmountOnLinuxClientScript > ~/$unmountOnLinuxClientScript"
    ExecCmdMaster "sudo rm -rf ~/$tempUnmountOnLinuxClientScript"
    ExecCmdMaster "sudo chown -R remote  /home/remote/$unmountOnLinuxClientScript"
    ExecCmdMaster "sudo chmod +x /home/remote/$unmountOnLinuxClientScript"

    Write-Log '           Executing on client unmount script inside Linux VM as remote user...'
    ssh.exe -n '-vv' -E $logFile -o StrictHostKeyChecking=no -i $global:LinuxVMKey $global:Remote_Master "sudo su -s /bin/bash -c '~/$unmountOnLinuxClientScript' remote"
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Unmounting '$linuxLocalPath -> $global:IP_NextHop/$windowsShareName' on Linux succeeded."
    }
    else {
        Write-Log "Unmounting '$linuxLocalPath -> $global:IP_NextHop/$windowsShareName' on Linux failed with code '$LASTEXITCODE'."
    }
}

function Wait-ForSharedFolderMountOnLinuxClient () {
    Write-Log 'Waiting for shared folder mount on Linux node..'
    $fstabOut = $(ExecCmdMaster 'cat /etc/fstab | grep /k8s-smb-share' -NoLog)
    if (! $fstabOut) {
        Write-Log 'no shared folder in fstab yet'
        # no entry in fstab, so no need to wait for mount
        return
    }

    $mountOut = $(ExecCmdMaster "sudo su -s /bin/bash -c 'sudo mount | grep /k8s-smb-share' remote" -NoLog)
    $iteration = 0
    while (! $mountOut) {
        $iteration++
        if ($iteration -ge 15) {
            Write-Log 'CIFS mount still not available, checking known issues ...'
            Test-ForKnownSmbProblems

            if ( $script:HasIssues -eq $true ) {
                Write-Log '              Executing script to fix policy issue...'
                & "$global:KubernetesPath\smallsetup\helpers\SetNetworkSharePolicy.ps1"
            }
        }
        if ($iteration -ge 20) {
            Write-Log 'CIFS mount still not available, aborting...'
            Test-ForKnownSmbProblems
            throw 'Unable to mount shared folder with CIFS'
        }
        if ($iteration -ge 2 ) {
            Write-Log 'CIFS mount not yet available, waiting for it...'
        }
        Start-Sleep 2
        ExecCmdMaster 'sudo mount -a'
        $mountOut = $(ExecCmdMaster "sudo su -s /bin/bash -c 'sudo mount | grep /k8s-smb-share' remote" -NoLog)
    }
    Write-Log 'Shared folder mounted on Linux.'
}

function Wait-ForSharedFolderOnLinuxHost () {
    Write-Log 'Waiting for shared folder (Samba Share) hosted on Linux node..'
    $script:Success = $false

    $fstabOut = $(ExecCmdMaster 'cat /etc/fstab | grep k8sshare' -NoLog)
    if (! $fstabOut) {
        Write-Log '           no shared folder in fstab yet'
        # no entry in fstab, so no need to wait for mount
        return
    }

    $mountOut = $(ExecCmdMaster "sudo su -s /bin/bash -c 'sudo mount | grep /k8s-smb-share' remote" -NoLog)
    $iteration = 0
    while (! $mountOut) {
        $iteration++
        if ($iteration -ge 15) {
            Write-Log "           $global:ShareMountPointInVm still not mounted, aborting."
            return
        }

        if ($iteration -ge 2 ) {
            Write-Log "           $global:ShareMountPointInVm not yet mounted, waiting for it..."
        }

        Start-Sleep 2
        ExecCmdMaster 'sudo mount -a' -NoLog
        $mountOut = $(ExecCmdMaster "sudo su -s /bin/bash -c 'sudo mount | grep /k8s-smb-share' remote" -NoLog)
    }
    Write-Log "           $global:ShareMountPointInVm mounted"
    $script:Success = $true
}

function New-SharedFolderMountOnLinuxHost {
    Remove-Item -Force -ErrorAction SilentlyContinue $logFile

    Write-Log '           Creating temporary mount script...'

    $fstabCmd = @"
        findmnt $global:ShareMountPointInVm -D >/dev/null && sudo umount $global:ShareMountPointInVm
        sudo rm -rf $global:ShareMountPointInVm
        sudo mkdir -p $global:ShareMountPointInVm
        mkdir -p ~/tmp
        cd ~/tmp
        # remove all old lines with $global:ShareMountPointInVm from fstab
        sed -e /k8s-smb-share/d < /etc/fstab > fstab.tmp
        # add the new line to fstab
        echo '             Adding line for $global:ShareMountPointInVm to /etc/fstab'
        echo '//$global:IP_Master/$linuxShareName $global:ShareMountPointInVm cifs username=$smbUserName,password=$($creds.GetNetworkCredential().Password),rw,nobrl,x-systemd.after=smbd.service,x-systemd.before=kubelet.service,file_mode=0666,dir_mode=0777,vers=3' >> fstab.tmp
        sudo sh -c "cat fstab.tmp > /etc/fstab"
        # immediately perform the mount
        echo '             Mount $global:ShareMountPointInVm from /etc/fstab entry'
        findmnt $global:ShareMountPointInVm -D >/dev/null || sudo mount $global:ShareMountPointInVm || exit 1
        echo '             Touch $global:ShareMountPointInVm/mountedInVm.txt'
        date > $global:ShareMountPointInVm/mountedInVm.txt || exit 1
        rm ~/tmp_fstabCmd.sh
"@

    $i = 0
    while ($true) {
        $i++
        # create the bash script, with \r characters removed (for Linux)
        Remove-Item "$global:KubernetesPath\tmp_fstab.sh" -ErrorAction Ignore
        $fstabCmd | Out-File -Encoding ascii "$global:KubernetesPath\tmp_fstab.sh"
        $source = "$global:KubernetesPath\tmp_fstab.sh"
        $target = "$global:Remote_Master" + ':/home/remote/'
        Copy-FromToMaster -Source $source -Target $target
        Remove-Item "$global:KubernetesPath\tmp_fstab.sh" -ErrorAction Ignore

        ExecCmdMaster 'sudo rm -rf ~/tmp_fstabCmd.sh'
        ExecCmdMaster "sed 's/\r//g' ~/tmp_fstab.sh > ~/tmp_fstabCmd.sh"
        ExecCmdMaster 'sudo rm -rf ~/tmp_fstab.sh'
        ExecCmdMaster 'sudo chown -R remote /home/remote/tmp_fstabCmd.sh'
        ExecCmdMaster 'sudo chmod +x /home/remote/tmp_fstabCmd.sh'

        Write-Log '           Executing script inside VM as remote user...'
        ssh.exe -n '-vv' -E $logFile -o StrictHostKeyChecking=no -i $global:LinuxVMKey $global:Remote_Master "sudo su -s /bin/bash -c '~/tmp_fstabCmd.sh' remote"
        if ($LASTEXITCODE -eq 0) {
            # all ok
            break
        }
        if ($i -ge 30) {
            Test-ForKnownSmbProblems
            throw 'unable to mount shared CF in Linux machine, giving up'
        }
        Start-Sleep 2
        Write-Log '           Retry after failure...'
    }
}

function Remove-SharedFolderMountOnLinuxHost {
    Write-Log "Unmounting '$global:ShareMountPointInVm' on Linux.."
    Remove-Item -Force -ErrorAction SilentlyContinue $logFile

    Write-Log 'Creating temporary unmount script..'
    $tempFstabFile = 'fstab.tmp'
    $tempUnmountOnLinuxHostScript = 'tmp_unmountOnLinuxHostCmd.sh'
    $unmountOnLinuxHostScript = 'unmountOnLinuxHostCmd.sh'
    $unmountOnLinuxHostCmd = @"
        findmnt $global:ShareMountPointInVm -D >/dev/null && sudo umount $global:ShareMountPointInVm
        mkdir -p ~/tmp
        cd ~/tmp
        # remove all lines with $global:ShareMountPointInVm from fstab
        sed -e /k8s-smb-share/d < /etc/fstab > $tempFstabFile
        sudo sh -c "cat $tempFstabFile > /etc/fstab"
        sudo rm -f $tempFstabFile
        sudo systemctl daemon-reload
        sudo rm -rf $global:ShareMountPointInVm
        rm ~/$unmountOnLinuxHostScript
"@

    # create the bash script, with \r characters removed (for Linux)
    $tempUnmountScript = "$global:KubernetesPath\$tempUnmountOnLinuxHostScript"
    Remove-Item $tempUnmountScript -ErrorAction Ignore
    $unmountOnLinuxHostCmd | Out-File -Encoding ascii $tempUnmountScript
    $target = "$global:Remote_Master" + ':/home/remote/'
    Copy-FromToMaster -Source $tempUnmountScript -Target $target
    Remove-Item $tempUnmountScript -ErrorAction Ignore

    ExecCmdMaster "sudo rm -rf ~/$unmountOnLinuxHostScript"
    ExecCmdMaster "sed 's/\r//g' ~/$tempUnmountOnLinuxHostScript > ~/$unmountOnLinuxHostScript"
    ExecCmdMaster "sudo rm -rf ~/$tempUnmountOnLinuxHostScript"
    ExecCmdMaster "sudo chown -R remote /home/remote/$unmountOnLinuxHostScript"
    ExecCmdMaster "sudo chmod +x /home/remote/$unmountOnLinuxHostScript"

    Write-Log '           Executing on host unmount script inside VM as remote user...'
    ssh.exe -n '-vv' -E $logFile -o StrictHostKeyChecking=no -i $global:LinuxVMKey $global:Remote_Master "sudo su -s /bin/bash -l -c '~/$unmountOnLinuxHostScript' remote"
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Unmounting '$global:ShareMountPointInVm' on Linux succeeded."
    }
    else {
        Write-Log "Unmounting '$global:ShareMountPointInVm' on Linux failed with code '$LASTEXITCODE'."
    }
}

function New-SharedFolderMountOnWindows {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $RemotePath = $(throw 'RemotePath not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $SmbUser = $(throw 'SmbUser not specified'),
        [Parameter(Mandatory = $false)]
        [SecureString]
        $SmbPasswd = $(throw 'SmbPasswd not specified')
    )
    Remove-LocalWinMountIfExisting
    Add-SmbGlobalMappingIfNotExisting -RemotePath $RemotePath -LocalPath $windowsLocalPath -SmbUser $SmbUser -SmbPasswd $SmbPasswd
    Add-SymLinkOnWindows -RemotePath $RemotePath
}

function Add-SymLinkOnWindows {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $RemotePath = $(throw 'RemotePath not specified')
    )
    New-Item -ItemType SymbolicLink -Path $windowsLocalPath -Target $RemotePath | Write-Log
    Write-Log "Symbolic Link '$windowsLocalPath --> $RemotePath' created."
}

function Add-SmbGlobalMappingIfNotExisting {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $RemotePath = $(throw 'RemotePath not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $LocalPath = $(throw 'LocalPath not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $SmbUser = $(throw 'SmbUser not specified'),
        [Parameter(Mandatory = $false)]
        [SecureString]
        $SmbPasswd = $(throw 'SmbPasswd not specified')
    )
    Write-Log "Mounting $LocalPath --> $RemotePath.." -Console

    if ($(Get-SmbGlobalMapping -RemotePath $RemotePath -ErrorAction SilentlyContinue)) {
        Write-Log "Mount $LocalPath --> $RemotePath already existing, nothing to create." -Console
        return
    }

    $creds = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $SmbUser, $SmbPasswd
    $iteration = 0;

    while (!$(Get-SmbGlobalMapping -RemotePath $RemotePath -ErrorAction SilentlyContinue)) {
        if ($iteration -gt 0) {
            Write-Log 'Retrying..'
        }

        $iteration++
        if ($iteration -ge 15) {
            throw "Mounting $LocalPath --> $RemotePath failed"
        }
        Start-Sleep 2
        New-SmbGlobalMapping -RemotePath "$RemotePath" -Credential $creds -UseWriteThrough $true -Persistent $true 2>&1 | Write-Log
    }

    Write-Log "$LocalPath --> $RemotePath mounted." -Console
}

function Restore-SmbShareAndFolderWindowsHost {
    param (
        [Parameter(Mandatory = $false)]
        [switch]
        $SkipTest = $false
    )
    Write-Log 'Restoring SMB share (Windows host)..' -Console

    if ($SkipTest -ne $true) {
        Test-SharedFolderMountOnWinNode

        if ($script:Success -eq $True) {
            Write-Log "           Access to shared folder '$windowsLocalPath' working, nothing to do"
            return
        }

        Write-Log "           No access to shared folder '$windowsLocalPath' yet, establishing it.."
    }

    New-SmbHostOnWindowsIfNotExisting
    New-SharedFolderMountOnLinuxClient
    Wait-ForSharedFolderMountOnLinuxClient
    Test-SharedFolderMountOnWinNode

    if ($script:Success -ne $True) {
        throw "Failed to setup SMB share '$windowsLocalPath' on Windows host"
    }

    Write-Log "           Access to shared folder '$windowsLocalPath' working" -Console
}

function New-StorageClassManifest {
    param (
        [parameter(Mandatory = $false)]
        [string]$RemotePath = $(throw 'RemotePath not specified')
    )
    $templateContent = Get-Content -Path $patchTemplateFilePath

    Write-Log "Template file <$patchTemplateFilePath> loaded."

    $remotePath = Convert-ToUnixPath -Path $RemotePath

    for ($i = 0; $i -lt $templateContent.Count; $i++) {
        if ($templateContent[$i] -like '*value:*') {
            $templateContent[$i] = "  value: `"$remotePath`""
            $found = $true
        }
    }

    if ($found -ne $true) {
        throw 'value section not found in template file'
    }

    Set-Content -Value $templateContent -Path $patchFilePath -Force

    Write-Log "StorageClass manifest written to '$patchFilePath'."
}

function Wait-ForStorageClassToBeReady {
    param (
        [Parameter(Mandatory = $false)]
        [int]
        $TimeoutSeconds = 30
    )
    Write-Log "Waiting for StorageClass to be ready (timeout: $($TimeoutSeconds)s).." -Console

    $ready = Test-CsiPodsCondition -Condition 'Ready' -TimeoutSeconds $TimeoutSeconds

    if ($true -ne $ready) {
        throw "StorageClass not ready within $($TimeoutSeconds)s"
    }

    Write-Log 'StorageClass is ready' -Console
}

function Wait-ForStorageClassToBeDeleted {
    param (
        [Parameter(Mandatory = $false)]
        [int]
        $TimeoutSeconds = 30
    )
    Write-Log "Waiting for StorageClass to be deleted (timeout: $($TimeoutSeconds)s).." -Console

    $deleted = Test-CsiPodsCondition -Condition 'Deleted' -TimeoutSeconds $TimeoutSeconds

    if ($true -ne $deleted) {
        Write-Log " StorageClass not deleted within $($TimeoutSeconds)s"
        return
    }

    Write-Log 'StorageClass is deleted successfully' -Console
}

function Restore-StorageClass {
    param (
        [parameter(Mandatory = $false)]
        [ValidateSet('windows', 'linux')]
        [string]$SmbHostType,
        [parameter(Mandatory = $false)]
        [bool]$LinuxOnly
    )
    $remotePath = $windowsHostRemotePath
    $manifestDir = $manifestWinDir

    if ($SmbHostType -eq 'linux') {
        $remotePath = $linuxHostRemotePath
    }

    if ($LinuxOnly -eq $true) {
        $manifestDir = $manifestBaseDir
    }

    Add-Secret -Name $smbCredsName -Namespace 'kube-system' -Literals "username=$smbUserName", "password=$($creds.GetNetworkCredential().Password)" | Write-Log

    New-StorageClassManifest -RemotePath $remotePath

    $params = 'apply', '-k', $manifestDir

    Write-Log "Invoking kubectl with '$params'.."

    $result = Invoke-Kubectl -Params $params
    if ($result.Success -ne $true) {
        throw $result.Output
    }

    Wait-ForStorageClassToBeReady -TimeoutSeconds $storageClassTimeoutSeconds
}

function Remove-StorageClass {
    param (
        [parameter(Mandatory = $false)]
        [bool]$LinuxOnly
    )
    $manifestDir = $manifestWinDir

    if ($LinuxOnly -eq $true) {
        $manifestDir = $manifestBaseDir
    }

    Remove-PersistentVolumeClaimsForStorageClass -StorageClass $smbStorageClassName | Write-Log

    if ((Test-Path -Path $patchFilePath) -eq $true) {
        $params = 'delete', '-k', $manifestDir

        Write-Log "Invoking kubectl with '$params'.."

        $result = Invoke-Kubectl -Params $params
        if ($result.Success -ne $true) {
            Write-Warning " Error occurred while invoking kubectl: $($result.Output)"
            return
        }

        Remove-Item -Path $patchFilePath -Force

        Wait-ForStorageClassToBeDeleted -TimeoutSeconds $storageClassTimeoutSeconds
    }
    else {
        Write-Log 'StorageClass manifest already deleted, skipping.'
    }

    Remove-Secret -Name $smbCredsName -Namespace 'kube-system' | Write-Log
}

function Remove-SmbShareAndFolderWindowsHost {
    param (
        [parameter(Mandatory = $false)]
        [switch]$SkipNodesCleanup = $false
    )
    Write-Log 'Removing SMB shares and folders hosted on Windows..'

    if ($SkipNodesCleanup -ne $true) {
        Remove-SharedFolderMountOnLinuxClient
    }

    Remove-SmbHostOnWindowsIfExisting
}

function Restore-SmbShareAndFolderLinuxHost {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$SkipTest = $false
    )
    Write-Log 'Restoring SMB share (Linux Samba host)..' -Console

    if ($SkipTest -ne $true) {
        Wait-ForSharedFolderOnLinuxHost

        if ($script:Success -eq $true) {
            Write-Log 'Samba share on Linux already working, checking mount on Windows node..'
            Test-SharedFolderMountOnWinNode
        }

        if ($script:Success -eq $true) {
            Write-Log "Access to shared folder '$windowsLocalPath' working, nothing to restore."
            return
        }

        Write-Log "No access to shared folder '$windowsLocalPath', establishing it.." -Console
    }

    New-SmbHostOnLinuxIfNotExisting
    New-SharedFolderMountOnLinuxHost
    Wait-ForSharedFolderOnLinuxHost

    if ($script:Success -ne $true) {
        throw 'Unable to mount shared folder with CIFS on Linux host'
    }

    Write-Log 'SMB share hosted and mounted on Linux, creating mount on Windows node..' -Console

    New-SharedFolderMountOnWindows -RemotePath $linuxHostRemotePath -SmbUser $smbFullUserNameLinux -SmbPasswd $smbPw

    Test-SharedFolderMountOnWinNode

    if ($script:Success -ne $true) {
        throw "Unable to setup SMB share '$windowsLocalPath' on Linux host"
    }

    Write-Log "           Access to shared folder '$windowsLocalPath' working" -Console
}

function Remove-SmbShareAndFolderLinuxHost {
    param (
        [parameter(Mandatory = $false)]
        [switch]$SkipNodesCleanup = $false
    )
    Write-Log 'Removing SMB shares and folders hosted on Linux..'

    Remove-SmbGlobalMappingIfExisting -RemotePath $linuxHostRemotePath
    Remove-LocalWinMountIfExisting

    if ($SkipNodesCleanup -ne $true) {
        Remove-SharedFolderMountOnLinuxHost
        Remove-SmbHostOnLinux
    }
}

function Add-SharedFolderToWinVM {
    param (
        [parameter(Mandatory = $false)]
        [ValidateSet('windows', 'linux')]
        [string]$SmbHostType
    )
    Write-Log "Setting up shared folder (SMB client) on Win VM with host type '$SmbHostType'.."

    $session = Open-RemoteSessionViaSSHKey $global:Admin_WinNode $global:WindowsVMKey -NoLog

    $isWinVmSmbShareWorking = (Get-IsWinVmSmbShareWorking -Session $session)

    if ($isWinVmSmbShareWorking -eq $true) {
        Write-Log 'Shared folder on Win VM already working, nothing to do.'
        return
    }

    Write-Log 'Shared folder not set up on Win VM yet, setting it up now..'

    Invoke-Command -Session $session {
        Set-ExecutionPolicy Bypass -Force -ErrorAction Continue

        Import-Module "$env:SystemDrive\k\addons\smb-share\module\Smb-share.module.psm1"
        Import-Module "$env:SystemDrive\k\smallsetup\ps-modules\log\log.module.psm1"
        Initialize-Logging -Nested:$true

        Connect-WinVMClientToSmbHost -SmbHostType:$using:SmbHostType

        $isWorking = Test-SharedFolderMountOnWinNodeSilently

        if ($isWorking -ne $true) {
            throw 'Shared folder on Windows WM not working.'
        }
    }

    Write-Log 'Shared folder on Win VM set up.'
}

function Remove-SharedFolderFromWinVM {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $RemotePath = $(throw 'RemotePath not specified')
    )
    Write-Log 'Removing shared folder (SMB client) mapping to '$RemotePath' on Win VM..'

    $session = Open-RemoteSessionViaSSHKey $global:Admin_WinNode $global:WindowsVMKey -NoLog

    Invoke-Command -Session $session {
        Set-ExecutionPolicy Bypass -Force -ErrorAction Continue

        Import-Module "$env:SystemDrive\k\addons\smb-share\module\Smb-share.module.psm1"
        Import-Module "$env:SystemDrive\k\smallsetup\ps-modules\log\log.module.psm1"
        Initialize-Logging -Nested:$true

        Remove-SmbGlobalMappingIfExisting -RemotePath $using:RemotePath
        Remove-LocalWinMountIfExisting
    }

    Write-Log 'Shared folder on Win VM removed.'
}

function Test-ClusterAvailability {
    $setupType = Get-SetupType

    if ($setupType.ValidationError) {
        throw $setupType.ValidationError
    }

    $clusterState = Get-RunningState -SetupType $setupType.Name

    if ($clusterState.IsRunning -ne $true) {
        throw "Cannot interact with '$AddonName' addon when cluster is not running. Please start the cluster with 'k2s start'."
    }
}

function Remove-SmbShareAndFolder() {
    param (
        [parameter(Mandatory = $false)]
        [switch]$SkipNodesCleanup = $false
    )
    Write-Log 'Removing SMB shares and folders..' -Console

    if ($SkipNodesCleanup -eq $true) {
        Write-Log 'Skipping SMB share cleanup on VMs..'
    }
    else {
        Test-ClusterAvailability
    }

    $smbHostType = Get-SmbHostType
    $setupType = Get-SetupType

    if ($SkipNodesCleanup -ne $true) {
        Remove-StorageClass -LinuxOnly $setupType.LinuxOnly
    }

    switch ($SmbHostType) {
        'windows' {
            Remove-SmbShareAndFolderWindowsHost -SkipNodesCleanup:$SkipNodesCleanup
            $remotePath = $windowsHostRemotePath
        }
        'linux' {
            Remove-SmbShareAndFolderLinuxHost -SkipNodesCleanup:$SkipNodesCleanup
            $remotePath = $linuxHostRemotePath
        }
        Default {
            throw "invalid SMB host type '$SmbHostType'"
        }
    }

    if ($SkipNodesCleanup -eq $true) {
        return
    }

    if ($setupType.Name -eq $global:SetupType_MultiVMK8s -and $setupType.LinuxOnly -ne $true) {
        Write-Log 'Removing shared folder from Win VM..'
        Remove-SharedFolderFromWinVM -RemotePath $remotePath
    }
}

function Test-SharedFolderMountOnWinNode {
    param (
        [Parameter(Mandatory = $false)]
        [switch]
        $Nested = $false
    )

    Write-Log 'Checking shared folder on Windows node..'
    $script:Success = $false

    if (!(Test-Path -path "$windowsLocalPath" -PathType Container)) {
        return
    }

    $testFileName = 'accessTest.flag'
    $winTestFile = "$windowsLocalPath\$testFileName"
    $linuxTestFile = "$linuxLocalPath/$testFileName"

    if (Test-Path $winTestFile) {
        Remove-Item -Force $winTestFile -ErrorAction Stop
    }

    Write-Log "           Create test file on linux side: $linuxTestFile"
    ExecCmdMaster "test -d $linuxLocalPath && sudo touch $linuxTestFile" -Nested:$Nested -Retries 10

    $iteration = 15
    while ($iteration -gt 0) {
        $iteration--
        if (Test-Path $winTestFile) {
            Write-Log "           Remove test file on windows side: $winTestFile"
            Remove-Item -Force $winTestFile -ErrorAction SilentlyContinue

            $script:Success = $true
            return
        }
        Start-Sleep 2
    }
    Write-Log "           Not accessable through windows, removing test file on linux side: $linuxTestFile ..."
    ExecCmdMaster "test -d $linuxLocalPath && sudo rm -f $linuxTestFile" -NoLog -Nested:$Nested
}

<#
.SYNOPSIS
Enables the SMB share addon

.DESCRIPTION
Enables the SMB share addon if not already enabled

.PARAMETER SmbHostType
Type of the SMB host, either Windows or Linux

.NOTES
- only works when cluster is running
- aborts when already installed/enabled
#>
function Enable-SmbShare {
    param (
        [parameter(Mandatory = $false)]
        [ValidateSet('windows', 'linux')]
        [string]$SmbHostType = $(throw 'SMB host type not set')
    )
    Test-ClusterAvailability

    if ((Test-IsAddonEnabled -Name $AddonName) -eq $true) {
        Write-Log "Addon '$AddonName' is already enabled, nothing to do."
        return
    }

    $setupType = Get-SetupType

    if ($setupType.Name -ne $global:SetupType_k2s -and $setupType.Name -ne $global:SetupType_MultiVMK8s) {
        throw "Addon '$AddonName' can only be enabled for '$global:SetupType_k2s' or '$global:SetupType_MultiVMK8s' setup type."
    }

    Copy-ScriptsToHooksDir -ScriptPaths $hookFilePaths
    Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = $AddonName; SmbHostType = $SmbHostType })
    Restore-SmbShareAndFolder -SmbHostType $SmbHostType -SkipTest -SetupType $setupType
    Restore-StorageClass -SmbHostType $SmbHostType -LinuxOnly $setupType.LinuxOnly

    Write-Log -Console '***************************************************************************************'
    Write-Log -Console '** IMPORTANT:                                                                        **' 
    Write-Log -Console "**       - use the StorageClass name '$smbStorageClassName' to provide storage.                       **"
    Write-Log -Console "**         See '<root>\test\e2e\addons\smb-share\workloads\' for example deployments.**"
    Write-Log -Console '***************************************************************************************'
}

<#
.SYNOPSIS
Disables the SMB share addon

.DESCRIPTION
Disables the SMB share addon if not already disabled

.PARAMETER SkipNodesCleanup
If set to $true, e.g. no Debian packages will be removed from the Linux VM (makes sense when uninstalling the K8s cluster). Default: $false

.NOTES
- only works when cluster is running
- aborts when already removed/disabled
#>
function Disable-SmbShare {
    param (
        [parameter(Mandatory = $false)]
        [switch]$SkipNodesCleanup = $false
    )
    if ((Test-IsAddonEnabled -Name $AddonName) -ne $true) {
        Write-Log "Addon '$AddonName' is already disabled, nothing to do."
        return
    }

    Write-Log "Disabling '$AddonName'.."

    Remove-SmbShareAndFolder -SkipNodesCleanup:$SkipNodesCleanup
    Remove-AddonFromSetupJson -Name $AddonName
    Remove-ScriptsFromHooksDir -ScriptNames $hookFileNames
}

<#
.SYNOPSIS
(Re-)Creates the SMB share

.DESCRIPTION
(Re-)Creates the SMB share (either due to install/enable or K8s cluster restart)

.PARAMETER SmbHostType
Type of the SMB host, either Windows or Linux

.PARAMETER SkipTest
If set to $true, checking for functional SMB share will be skipped, e.g. when enabling the addon. Default: $false
#>
function Restore-SmbShareAndFolder {
    param (
        [parameter(Mandatory = $false)]
        [ValidateSet('windows', 'linux')]
        [string]$SmbHostType,
        [parameter(Mandatory = $false)]
        [pscustomobject]$SetupType,
        [parameter(Mandatory = $false)]
        [switch]$SkipTest = $false
    )
    switch ($SmbHostType) {
        'windows' {
            Restore-SmbShareAndFolderWindowsHost -SkipTest:$SkipTest
        }
        'linux' {
            Restore-SmbShareAndFolderLinuxHost -SkipTest:$SkipTest
        }
        Default {
            throw "invalid SMB host type '$SmbHostType'"
        }
    }

    if ($SetupType.Name -eq $global:SetupType_MultiVMK8s -and $SetupType.LinuxOnly -ne $true) {
        Add-SharedFolderToWinVM -SmbHostType $SmbHostType
    }
}

<#
.SYNOPSIS
Reads the SMB host type from config

.DESCRIPTION
Reads the SMB host type from addons config file
#>
function Get-SmbHostType {
    $config = Get-AddonConfig -Name $AddonName

    return $config.SmbHostType
}

<#
.SYNOPSIS
Connects a Windows VM as client to an SMB host

.DESCRIPTION
Connects a Windows VM as client to an SMB host

.PARAMETER SmbHostType
Type of the SMB host, either Windows or Linux

.NOTES
- This function intended to be imported and executed on a Win VM node
- This function does not create a session to a VM
#>
function Connect-WinVMClientToSmbHost {
    Param(
        [parameter(Mandatory = $false)]
        [ValidateSet('windows', 'linux')]
        [string]$SmbHostType = $(throw 'SMB host type not specified')
    )
    switch ($SmbHostType) {
        'windows' {
            $remotePath = $windowsHostRemotePath
            $smbUser = $smbFullUserNameWin
        }
        'linux' {
            $remotePath = $linuxHostRemotePath
            $smbUser = $smbFullUserNameLinux
        }
        Default {
            throw "invalid SMB host type '$SmbHostType'"
        }
    }

    New-SharedFolderMountOnWindows -RemotePath $remotePath -SmbUser $smbUser -SmbPasswd $smbPw
}

<#
.SYNOPSIS
Checks the SMB share access

.DESCRIPTION
Checks the SMB share access on a Windows node

.NOTES
This function can be imported and executed on a Win VM node
#>
function Test-SharedFolderMountOnWinNodeSilently {
    Test-SharedFolderMountOnWinNode -Nested | Out-Null

    return $script:Success -eq $true
}

function Get-Status {
    $smbHostTypeProp = @{Name = 'SmbHostType'; Value = Get-SmbHostType }

    Test-IsSmbShareWorking | Out-Null

    $isSmbShareWorkingProp = @{Name = 'IsSmbShareWorking'; Value = $script:SmbShareWorking; Okay = $script:SmbShareWorking }
    if ($isSmbShareWorkingProp.Value -eq $true) {
        $isSmbShareWorkingProp.Message = 'The SMB share is working'
    }
    else {
        $isSmbShareWorkingProp.Message = "The SMB share is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable $AddonName' and 'k2s addons enable $AddonName'"
    }

    $areCsiPodsRunning = Test-CsiPodsCondition -Condition 'Ready'

    $areCsiPodsRunningProp = @{Name = 'AreCsiPodsRunning'; Value = $areCsiPodsRunning; Okay = $areCsiPodsRunning }
    if ($areCsiPodsRunningProp.Value -eq $true) {
        $areCsiPodsRunningProp.Message = 'The CSI Pods are running'
    }
    else {
        $areCsiPodsRunningProp.Message = "The CSI Pods are not running. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable $AddonName' and 'k2s addons enable $AddonName'"
    }

    return $smbHostTypeProp, $isSmbShareWorkingProp, $areCsiPodsRunningProp
}

<#
.SYNOPSIS
Creates an addon data backup

.DESCRIPTION
Creates an addon data backup

.PARAMETER BackupDir
Back-up directory to write data to (gets created if not existing)
#>
function Backup-AddonData {
    param (
        [Parameter(Mandatory = $false, HelpMessage = 'Back-up directory to write data to (gets created if not existing).')]
        [string]$BackupDir = $(throw 'Please specify the back-up directory.')
    )
    $BackupDir = "$BackupDir\$AddonName"

    if ((Test-Path $BackupDir) -ne $true) {
        Write-Log "  '$AddonName' backup dir not existing, creating it.."
        New-Item -Path $BackupDir -ItemType Directory -Force | Out-Null
    }

    Write-Log "  Copying data from '$windowsLocalPath' to '$BackupDir'.."
    Copy-Item "$windowsLocalPath\*" -Destination $BackupDir -Force -Recurse
    Write-Log "  Data copied to '$BackupDir'."
}

<#
.SYNOPSIS
Restores addon data from a backup

.DESCRIPTION
Restores addon data from a backup

.PARAMETER BackupDir
Back-up directory to restore data from
#>
function Restore-AddonData {
    param (
        [Parameter(Mandatory = $false, HelpMessage = 'Back-up directory to restore data from.')]
        [string]$BackupDir = $(throw 'Please specify the back-up directory.')
    )
    $BackupDir = "$BackupDir\$AddonName"

    if ((Test-Path $BackupDir) -ne $true) {
        Write-Log "  '$AddonName' backup dir not existing, skipping."
        return
    }

    Write-Log "  Copying data from '$BackupDir' to '$windowsLocalPath'.."
    Copy-Item "$BackupDir\*" -Destination $windowsLocalPath -Force -Recurse
    Write-Log "  Data copied to '$windowsLocalPath'."
}

<#
.SYNOPSIS
Removes the SMB global mapping from a Windows client

.DESCRIPTION
Removes the SMB global mapping from a Windows client if existing

.PARAMETER RemotePath
The SMB share remote path

.NOTES
This function can be imported and executed on a Win VM node
#>
function Remove-SmbGlobalMappingIfExisting {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $RemotePath = $(throw 'RemotePath not specified')
    )
    Write-Log "Removing SMB global mapping to '$RemotePath'.."

    $mapping = Get-SmbGlobalMapping -RemotePath $RemotePath -ErrorAction SilentlyContinue

    if ($null -eq $mapping) {
        Write-Log "Global SMB mapping to '$RemotePath' not existing, nothing to remove."
        return
    }

    Remove-SmbGlobalMapping -RemotePath $RemotePath -Force

    Write-Log "SMB global mapping to '$RemotePath' removed."
}

<#
.SYNOPSIS
Removes the local SMB mount from a Windows client

.DESCRIPTION
Removes the local SMB mount from a Windows client if existing

.NOTES
This function can be imported and executed on a Win VM node
#>
function Remove-LocalWinMountIfExisting {
    if ((Test-Path -Path $windowsLocalPath) -ne $true) {
        Write-Log 'Local Win mount not existing, nothing to remove.'
        return
    }

    $winMount = Get-Item $windowsLocalPath
    if ( ($winMount | Select-Object -Property LinkType).LinkType -eq 'SymbolicLink') {
        $winMount.Delete()

        Write-Log "SymbolicLink '$windowsLocalPath' deleted."
    }
    else {
        Remove-Item $windowsLocalPath -Recurse -Force

        Write-Log "Directory '$windowsLocalPath' deleted."
    }
}

Export-ModuleMember -Function Enable-SmbShare, Disable-SmbShare, Restore-SmbShareAndFolder, Get-SmbHostType,
Connect-WinVMClientToSmbHost, Test-SharedFolderMountOnWinNodeSilently, Get-Status, Backup-AddonData,
Restore-AddonData, Remove-SmbGlobalMappingIfExisting, Remove-LocalWinMountIfExisting -Variable AddonName