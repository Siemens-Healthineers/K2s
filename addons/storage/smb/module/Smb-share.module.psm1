# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

$infraModule = "$PSScriptRoot/../../../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$nodeModule = "$PSScriptRoot/../../../../lib/modules/k2s/k2s.node.module/k2s.node.module.psm1"
$addonsModule = "$PSScriptRoot/../../../addons.module.psm1"
$passwordModule = "$PSScriptRoot/password.module.psm1"

Import-Module $clusterModule, $infraModule, $nodeModule, $addonsModule, $passwordModule

$AddonName = 'storage'
$ImplementationName = 'smb'

$localHooksDir = "$PSScriptRoot\..\hooks"
$logFile = "$(Get-SystemDriveLetter):\var\log\ssh_smbSetup.log"

$smbUserName = 'remotesmb'
$smbFullUserNameWin = "$env:computername\$smbUserName"
$smbFullUserNameLinux = "$(Get-ConfigControlPlaneNodeHostname)\$smbUserName"
$smbPw = ConvertTo-SecureString $(Get-RandomPassword 25) -AsPlainText -Force
$creds = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $smbFullUserNameLinux, $smbPw
$smbCredsName = 'smbcreds'

$manifestBaseDir = "$PSScriptRoot\..\manifests\base"
$manifestStorageClassesDir = "$manifestBaseDir\storage-classes"
$manifestWinDir = "$PSScriptRoot\..\manifests\windows"

$scKustomizeFileName = 'kustomization.yaml'
$scKustomizeTemplateFileName = "template_$scKustomizeFileName"
$scTemplateFileName = 'template_StorageClass.yaml'
$scKustomizeTemplateFilePath = "$manifestStorageClassesDir\$scKustomizeTemplateFileName"
$scTemplateFilePath = "$manifestStorageClassesDir\$scTemplateFileName"
$storageClassNamePlaceholder = 'SC_NAME'
$storageClassSourcePlaceholder = 'SC_SOURCE'
$kustomizeResourcesPlaceholder = 'SC_RESOURCES'
$generatedPrefix = 'generated_'

$storageClassTimeoutSeconds = 600
$namespace = 'storage-smb'

$configFilePath = "$PSScriptRoot\..\Config\SmbStorage.json"

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
    $csiSmbLinuxNodePodCondition = Wait-ForPodCondition -Condition $Condition -Label 'app=csi-smb-node' -Namespace $namespace -TimeoutSeconds $TimeoutSeconds
    if ($false -eq $csiSmbLinuxNodePodCondition) {
        return $false
    }

    $csiSmbControllerPodCondition = Wait-ForPodCondition -Condition $Condition -Label 'app=csi-smb-controller' -Namespace $namespace -TimeoutSeconds $TimeoutSeconds
    if ($false -eq $csiSmbControllerPodCondition) {
        return $false
    }

    $setupInfo = Get-SetupInfo
    if ($setupInfo.LinuxOnly -eq $true) {
        return $true
    }

    $csiSmbWindowsNodePodCondition = Wait-ForPodCondition -Condition $Condition -Label 'app=csi-smb-node-win' -Namespace $namespace -TimeoutSeconds $TimeoutSeconds
    if ($false -eq $csiSmbWindowsNodePodCondition) {
        return $false
    }

    $csiProxyPodCondition = Wait-ForPodCondition -Condition $Condition -Label 'k8s-app=csi-proxy' -Namespace $namespace -TimeoutSeconds $TimeoutSeconds
    return $true -eq $csiProxyPodCondition
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
    param (
        [parameter(Mandatory = $false)]
        [pscustomobject]$Config = $(throw 'Config not specified')
    )

    Write-Log "Checking if VM is running for Name='$Name'.."

    $smb = Get-SmbShare -Name $Config.WinShareName -ErrorAction SilentlyContinue
    if ($smb) {
        Write-Log "SMB host '$($Config.WinShareName)' on Windows already existing, nothing to create."
        return
    }

    Write-Log "Setting up '$($Config.WinShareName)' SMB host on Windows.."

    if (Get-LocalUser -Name $smbUserName -ErrorAction SilentlyContinue) {
        Write-Log "User '$smbUserName' already exists."
    }
    else {
        New-LocalUser -Name $smbUserName -Password $smbPw -Description 'A K2s user account for SMB access' -ErrorAction Stop | Out-Null # Description max. length seems to be 48 chars ?!
        $RemoteUsersGroup = 'Remote Desktop Users'
        if ((Get-LocalGroup -Name $RemoteUsersGroup -ErrorAction SilentlyContinue).Count -gt 0) {
            Write-Log "The '$RemoteUsersGroup' group exists, user '$smbUserName' will be added to this group."
            Add-LocalGroupMember -Group $RemoteUsersGroup -Member $smbUserName 
        }
        else {
            Write-Log "The '$RemoteUsersGroup' group does not exist, skipping adding user to this group."
        }
    }
    
    mkdir -Path $Config.WinMountPath -Force -ErrorAction SilentlyContinue | Out-Null
    New-SmbShare -Name $Config.WinShareName -Path $Config.WinMountPath -FullAccess $smbFullUserNameWin -ErrorAction Stop | Out-Null
    Add-FirewallExceptions

    Write-Log " '$($Config.WinShareName)'SMB host set up Windows."
}

function Remove-SmbHostOnWindowsIfExisting {
    param (
        [parameter(Mandatory = $false)]
        [pscustomobject]$Config = $(throw 'Config not specified'),
        [parameter(Mandatory = $false)]
        [switch]$Keep = $false
    )

    $smb = Get-SmbShare -Name $Config.WinShareName -ErrorAction SilentlyContinue
    if ($null -eq $smb) {
        Write-Log "SMB host '$($Config.WinShareName)' on Windows not existing, nothing to remove."
        return
    }

    Write-Log "Removing '$($Config.WinShareName)' SMB host from Windows.."

    Remove-FirewallExceptions
    Remove-SmbShare -Name $($Config.WinShareName) -Confirm:$False -ErrorAction SilentlyContinue
    if ( -not $Keep ) {
        # if we do not want to keep the mount point, we remove it
        Write-Log "Removing mount point '$($Config.WinMountPath)' from Windows.."
        Remove-Item -Force $Config.WinMountPath -Recurse -Confirm:$False -ErrorAction SilentlyContinue
    }
    else {
        Write-Log "Keeping mount point '$($Config.WinMountPath)' on Windows."
    }

    Remove-LocalUser -Name $smbUserName -ErrorAction SilentlyContinue

    Write-Log " '$($Config.WinShareName)' SMB host removed from Windows."
}

function New-SmbHostOnLinuxIfNotExisting {
    param (
        [parameter(Mandatory = $false)]
        [pscustomobject]$Config = $(throw 'Config not specified')
    )

    # We try to access the samba share on windows side.
    # If this is not possible, we set up Samba on linux and create the shared CF - NOT the mount points yet!
    # The Samba Shared CF will be \srv\samba\<linux share name>
    New-SmbGlobalMapping -RemotePath $Config.LinuxHostRemotePath -Credential $creds -UseWriteThrough $true -Persistent $true -ErrorAction SilentlyContinue

    if ((Test-Path $Config.LinuxHostRemotePath)) {
        Write-Log 'SMB host on Linux already existing, nothing to create'
        return
    }

    Write-Log 'Setting up SMB host on Linux (Samba Share)..'

    # restart dnsmsq in order to reconnect to dnsproxy
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo systemctl restart dnsmasq').Output | Write-Log

    # download samba and rest
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq --yes').Output | Write-Log

    Install-DebianPackages -addon 'storage' -implementation 'smb' -packages 'cifs-utils', 'samba'

    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo adduser --no-create-home --disabled-password --disabled-login --gecos '' $smbUserName").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "(echo '$($creds.GetNetworkCredential().Password)'; echo '$($creds.GetNetworkCredential().Password)') | sudo smbpasswd -s -a $smbUserName" -NoLog).Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo smbpasswd -e $smbUserName").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo mkdir -p /srv/samba/$($Config.LinuxShareName)").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo chown nobody:nogroup /srv/samba/$($Config.LinuxShareName)/").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo chmod 0777 /srv/samba/$($Config.LinuxShareName)/").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo sh -c 'echo [$($Config.LinuxShareName)] >> /etc/samba/smb.conf'").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo sh -c 'echo comment = K8s share using $($Config.LinuxShareName) >> /etc/samba/smb.conf'").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo sh -c 'echo path = /srv/samba/$($Config.LinuxShareName) >> /etc/samba/smb.conf'").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo sh -c 'echo browsable = yes >> /etc/samba/smb.conf'").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo sh -c 'echo guest ok = yes >> /etc/samba/smb.conf'").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo sh -c 'echo read only = no >> /etc/samba/smb.conf'").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo sh -c 'echo create mask = 0777 >> /etc/samba/smb.conf'").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo sh -c 'echo directory mask = 0777 >> /etc/samba/smb.conf'").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo systemctl restart smbd.service nmbd.service').Output | Write-Log

    Write-Log ' SMB host on Linux (Samba Share) set up.'
}

function Remove-SmbHostOnLinux {
    param (
        [parameter(Mandatory = $false)]
        [string]$LinuxShareName = $(throw 'LinuxShareName not specified'),
        [parameter(Mandatory = $false)]
        [switch]$Keep = $false
    )  

    Write-Log 'Removing SMB host on Linux (Samba Share)..'

    if ($Keep -eq $true) {
        Write-Log "Keeping SMB share '$LinuxShareName' on Linux host."
    }
    else {
        Write-Log "Removing SMB share '$LinuxShareName' on Linux host."
        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo rm -rf /srv/samba/$LinuxShareName").Output | Write-Log
    }   

    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo smbpasswd -x $smbUserName").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo DEBIAN_FRONTEND=noninteractive apt-get purge cifs-utils samba samba-* -qq -y').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo DEBIAN_FRONTEND=noninteractive apt-get autoremove -qq -y').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo rm -rf /var/cache/samba /run/samba /srv/samba /var/lib/samba /var/log/samba').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo deluser $smbUserName").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo systemctl daemon-reload').Output | Write-Log

    Write-Log 'SMB host on Linux (Samba Share) removed'
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

    Write-Log 'No known SMB issues found'
}

function New-SharedFolderMountOnLinuxClient {
    param (
        [parameter(Mandatory = $false)]
        [pscustomobject]$Config = $(throw 'Config not specified')
    )    

    Write-Log "Mounting '$($Config.LinuxMountPath) -> $($Config.WinHostRemotePath)' on Linux.."
    Remove-Item -Force -ErrorAction SilentlyContinue $logFile

    Write-Log 'Creating temporary mount script..'
    $tempFstabFile = 'fstab.tmp'
    $tempMountOnLinuxClientScript = 'tmp_mountOnLinuxClientCmd.sh'
    $mountOnLinuxClientScript = 'mountOnLinuxClientCmd.sh'
    $mountOnLinuxClientCmd = @"
        findmnt $($Config.LinuxMountPath) -D >/dev/null && sudo umount $($Config.LinuxMountPath)
        sudo rm -rf $($Config.LinuxMountPath)
        sudo mkdir -p $($Config.LinuxMountPath)
        mkdir -p ~/tmp
        cd ~/tmp
        # remove all old lines with $($Config.WinShareName) from fstab
        sed -e /$($Config.WinShareName)/d < /etc/fstab > $tempFstabFile
        # add the new line to fstab
        echo '             Adding line for $($Config.LinuxMountPath) to /etc/fstab'
        echo '//$(Get-ConfiguredKubeSwitchIP)/$($Config.WinShareName) $($Config.LinuxMountPath) cifs username=$smbUserName,password=$($creds.GetNetworkCredential().Password),rw,nobrl,soft,x-systemd.automount,file_mode=0666,dir_mode=0777,vers=3.0' | tee -a $tempFstabFile >/dev/null
        sudo sh -c "cat $tempFstabFile > /etc/fstab"
        sudo rm -f $tempFstabFile
        # immediately perform the mount
        echo '             Mount $($Config.LinuxMountPath) from /etc/fstab entry'
        findmnt $($Config.LinuxMountPath) -D >/dev/null || sudo mount $($Config.LinuxMountPath) || exit 1
        echo '             Touch $($Config.LinuxMountPath)/mountedInVm.txt'
        date > $($Config.LinuxMountPath)/mountedInVm.txt || exit 1
        rm ~/$mountOnLinuxClientScript
"@

    $i = 0
    while ($true) {
        $i++
        # create the bash script, with \r characters removed (for Linux)
        $tempMountScript = "$(Get-KubePath)\$tempMountOnLinuxClientScript"
        Remove-Item $tempMountScript -ErrorAction Ignore
        $mountOnLinuxClientCmd | Out-File -Encoding ascii $tempMountScript
        Copy-ToControlPlaneViaSSHKey -Source $tempMountScript -Target '/home/remote/'
        Remove-Item $tempMountScript -ErrorAction Ignore

        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo rm -rf ~/$mountOnLinuxClientScript").Output | Write-Log
        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sed 's/\r//g' ~/$tempMountOnLinuxClientScript > ~/$mountOnLinuxClientScript").Output | Write-Log
        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo rm -rf ~/$tempMountOnLinuxClientScript").Output | Write-Log
        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo chown -R remote  /home/remote/$mountOnLinuxClientScript").Output | Write-Log
        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo chmod +x /home/remote/$mountOnLinuxClientScript").Output | Write-Log

        Write-Log 'Executing script inside Linux VM as remote user...'
        $sshLog = (ssh.exe -n '-vv' -E $logFile -o StrictHostKeyChecking=no -i $(Get-SSHKeyControlPlane) $(Get-ControlPlaneRemoteUser) "sudo su -s /bin/bash -c '~/$mountOnLinuxClientScript' remote") *>&1
        Write-Log " $sshLog"

        if ($LASTEXITCODE -eq 0) {
            # all ok
            break
        }
        if ($i -ge 3) {
            Test-ForKnownSmbProblems

            if ( $script:HasIssues -eq $true ) {
                Write-Log 'Executing script to fix policy issue...'
                & "$PSScriptRoot\SetNetworkSharePolicy.ps1"
            }
        }
        if ($i -ge 6) {
            Test-ForKnownSmbProblems
            throw 'unable to mount shared CF in Linux machine, giving up'
        }
        Start-Sleep 2
        Write-Log 'Retry after failure...'
    }
}

function Remove-SharedFolderMountOnLinuxClient {
    param (
        [parameter(Mandatory = $false)]
        [pscustomobject]$Config = $(throw 'Config not specified'),
        [parameter(Mandatory = $false)]
        [switch]$Keep = $false 
    ) 

    Write-Log "Unmounting '$($Config.LinuxMountPath) -> $($Config.WinHostRemotePath)' on Linux.."
    Remove-Item -Force -ErrorAction SilentlyContinue $logFile

    Write-Log 'Creating temporary unmount script..'

    $tempFstabFile = 'fstab.tmp'
    $tempUnmountOnLinuxClientScript = 'tmp_unmountOnLinuxClientCmd.sh'
    $unmountOnLinuxClientScript = 'unmountOnLinuxClientCmd.sh'
    $unmountOnLinuxClientCmd = @"
        findmnt $($Config.LinuxMountPath) -D >/dev/null && sudo umount $($Config.LinuxMountPath)
        mkdir -p ~/tmp
        cd ~/tmp
        # remove all lines with $($Config.WinShareName) from fstab
        sed -e /$($Config.WinShareName)/d < /etc/fstab > $tempFstabFile
        sudo sh -c "cat $tempFstabFile > /etc/fstab"
        sudo rm -f $tempFstabFile
        sudo systemctl daemon-reload
        rm ~/$unmountOnLinuxClientScript
        sudo rm -rf $($Config.LinuxMountPath)
"@
    # if we want to keep content of the mount point, we do not remove it
    if (-not $Keep) {
        $unmountOnLinuxClientCmd += @"
        sudo rm -rf $($Config.LinuxMountPath)
"@
    } 

    # create the bash script, with \r characters removed (for Linux)
    $tempUnmountScript = "$(Get-KubePath)\$tempUnmountOnLinuxClientScript"
    Remove-Item $tempUnmountScript -ErrorAction Ignore
    $unmountOnLinuxClientCmd | Out-File -Encoding ascii $tempUnmountScript
    Copy-ToControlPlaneViaSSHKey -Source $tempUnmountScript -Target '/home/remote/'
    Remove-Item $tempUnmountScript -ErrorAction Ignore

    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo rm -rf ~/$unmountOnLinuxClientScript").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sed 's/\r//g' ~/$tempUnmountOnLinuxClientScript > ~/$unmountOnLinuxClientScript").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo rm -rf ~/$tempUnmountOnLinuxClientScript").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo chown -R remote  /home/remote/$unmountOnLinuxClientScript").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo chmod +x /home/remote/$unmountOnLinuxClientScript").Output | Write-Log

    Write-Log 'Executing on client unmount script inside Linux VM as remote user...'
    $sshLog = (ssh.exe -n '-vv' -E $logFile -o StrictHostKeyChecking=no -i $(Get-SSHKeyControlPlane) $(Get-ControlPlaneRemoteUser) "sudo su -s /bin/bash -c '~/$unmountOnLinuxClientScript' remote") *>&1
    Write-Log " $sshLog"

    $resultMsg = Write-Log "Unmounting '$($Config.LinuxMountPath) -> $($Config.WinHostRemotePath)' on Linux "
    if ($LASTEXITCODE -eq 0) {
        $resultMsg += 'succeeded.'
    }
    else {
        $resultMsg += "failed with code '$LASTEXITCODE'."
    }
    Write-Log $resultMsg    
}

function Wait-ForSharedFolderMountOnLinuxClient () {
    param (
        [parameter(Mandatory = $false)]
        [pscustomobject]$Config = $(throw 'Config not specified')
    )
    
    Write-Log 'Waiting for shared folder mount on Linux node..'
    $fstabOut = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "cat /etc/fstab | grep -o /$($Config.WinShareName)").Output
    if (! $fstabOut) {
        Write-Log 'no shared folder in fstab yet'
        # no entry in fstab, so no need to wait for mount
        return
    }

    $mountOut = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo su -s /bin/bash -c 'sudo mount | grep /$($Config.WinShareName)' remote").Output

    $iteration = 0
    while (! $mountOut) {
        $iteration++
        if ($iteration -ge 15) {
            Write-Log 'CIFS mount still not available, checking known issues ...'
            Test-ForKnownSmbProblems

            if ( $script:HasIssues -eq $true ) {
                Write-Log 'Executing script to fix policy issue...'
                & "$PSScriptRoot\SetNetworkSharePolicy.ps1"
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
        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo mount -a').Output | Write-Log
        $mountOut = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo su -s /bin/bash -c 'sudo mount | grep /$($Config.WinShareName)' remote").Output
    }
    Write-Log 'Shared folder mounted on Linux.'
}

function Wait-ForSharedFolderOnLinuxHost () {
    param (
        [parameter(Mandatory = $false)]
        [pscustomobject]$Config = $(throw 'Config not specified')
    )    

    Write-Log 'Waiting for shared folder (Samba Share) hosted on Linux node..'
    $script:Success = $false

    $fstabOut = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "cat /etc/fstab | grep -o $($Config.LinuxShareName)").Output
    if (! $fstabOut) {
        Write-Log 'no shared folder in fstab yet'
        # no entry in fstab, so no need to wait for mount
        return
    }

    $mountOut = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo su -s /bin/bash -c 'sudo mount | grep /$($Config.LinuxShareName)' remote").Output
    $iteration = 0
    while (! $mountOut) {
        $iteration++
        if ($iteration -ge 15) {
            Write-Log "$($Config.LinuxMountPath) still not mounted, aborting."
            return
        }

        if ($iteration -ge 2 ) {
            Write-Log "$($Config.LinuxMountPath) not yet mounted, waiting for it..."
        }

        Start-Sleep 2
        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo mount -a').Output | Write-Log
        $mountOut = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo su -s /bin/bash -c 'sudo mount | grep /$($Config.LinuxShareName)' remote").Output
    }
    Write-Log "'$($Config.LinuxMountPath)' mounted"
    $script:Success = $true
}

function New-SharedFolderMountOnLinuxHost {
    param (
        [parameter(Mandatory = $false)]
        [pscustomobject]$Config = $(throw 'Config not specified')
    )  

    Remove-Item -Force -ErrorAction SilentlyContinue $logFile

    Write-Log 'Creating temporary mount script...'

    $fstabCmd = @"
        findmnt $($Config.LinuxMountPath) -D >/dev/null && sudo umount $($Config.LinuxMountPath)
        sudo rm -rf $($Config.LinuxMountPath)
        sudo mkdir -p $($Config.LinuxMountPath)
        mkdir -p ~/tmp
        cd ~/tmp
        # remove all old lines with $($Config.LinuxMountPath) from fstab
        sed -e /$($Config.LinuxShareName)/d < /etc/fstab > fstab.tmp
        # add the new line to fstab
        echo '             Adding line for $($Config.LinuxMountPath) to /etc/fstab'
        echo '//$(Get-ConfiguredIPControlPlane)/$($Config.LinuxShareName) $($Config.LinuxMountPath) cifs username=$smbUserName,password=$($creds.GetNetworkCredential().Password),rw,nobrl,x-systemd.after=smbd.service,x-systemd.before=kubelet.service,file_mode=0666,dir_mode=0777,vers=3' | tee -a fstab.tmp >/dev/null
        sudo sh -c "cat fstab.tmp > /etc/fstab"
        # immediately perform the mount
        echo '             Mount $($Config.LinuxMountPath) from /etc/fstab entry'
        findmnt $($Config.LinuxMountPath) -D >/dev/null || sudo mount $($Config.LinuxMountPath) || exit 1
        echo '             Touch $($Config.LinuxMountPath)/mountedInVm.txt'
        date > $($Config.LinuxMountPath)/mountedInVm.txt || exit 1
        rm ~/tmp_fstabCmd.sh
"@

    $i = 0
    while ($true) {
        $i++
        # create the bash script, with \r characters removed (for Linux)
        $localTempFile = "$(Get-KubePath)\tmp_fstab.sh"
        Remove-Item $localTempFile -ErrorAction Ignore
        $fstabCmd | Out-File -Encoding ascii $localTempFile
        Copy-ToControlPlaneViaSSHKey -Source $localTempFile -Target '/home/remote/'
        Remove-Item $localTempFile -ErrorAction Ignore

        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo rm -rf ~/tmp_fstabCmd.sh').Output | Write-Log
        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sed 's/\r//g' ~/tmp_fstab.sh > ~/tmp_fstabCmd.sh").Output | Write-Log
        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo rm -rf ~/tmp_fstab.sh').Output | Write-Log
        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo chown -R remote /home/remote/tmp_fstabCmd.sh').Output | Write-Log
        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo chmod +x /home/remote/tmp_fstabCmd.sh').Output | Write-Log

        Write-Log 'Executing script inside VM as remote user...'
        Start-Sleep 2
        ssh.exe -n '-vv' -E $logFile -o StrictHostKeyChecking=no -i $(Get-SSHKeyControlPlane) $(Get-ControlPlaneRemoteUser) "sudo su -s /bin/bash -c '~/tmp_fstabCmd.sh' remote"
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Successfully mounted '$($Config.LinuxMountPath)' on Linux."
            break
        }
        if ($i -ge 30) {
            Test-ForKnownSmbProblems
            throw 'unable to mount shared CF in Linux machine, giving up'
        }
        Write-Log 'Retry after failure...'
    }
}

function Remove-SharedFolderMountOnLinuxHost {
    param (
        [parameter(Mandatory = $false)]
        [pscustomobject]$Config = $(throw 'Config not specified'),
        [parameter(Mandatory = $false)]
        [switch]$Keep = $false
    )    

    Write-Log "Unmounting '$($Config.LinuxMountPath)' on Linux.."
    Remove-Item -Force -ErrorAction SilentlyContinue $logFile

    Write-Log 'Creating temporary unmount script..'
    $tempFstabFile = 'fstab.tmp'
    $tempUnmountOnLinuxHostScript = 'tmp_unmountOnLinuxHostCmd.sh'
    $unmountOnLinuxHostScript = 'unmountOnLinuxHostCmd.sh'
    $unmountOnLinuxHostCmd = @"
        findmnt $($Config.LinuxMountPath) -D >/dev/null && sudo umount $($Config.LinuxMountPath)
        mkdir -p ~/tmp
        cd ~/tmp
        # remove all lines with $($Config.LinuxMountPath) from fstab
        sed -e /$($Config.LinuxShareName)/d < /etc/fstab > $tempFstabFile
        sudo sh -c "cat $tempFstabFile > /etc/fstab"
        sudo rm -f $tempFstabFile
        sudo systemctl daemon-reload
        sudo rm ~/$unmountOnLinuxHostScript
"@
    # if we want to keep content of the mount point, we do not remove it
    if (-not $Keep) {
        $unmountOnLinuxHostCmd += @"
        sudo rm -rf $($Config.LinuxMountPath)   
"@
    }

    # create the bash script, with \r characters removed (for Linux)
    $tempUnmountScript = "$(Get-KubePath)\$tempUnmountOnLinuxHostScript"
    Remove-Item $tempUnmountScript -ErrorAction Ignore
    $unmountOnLinuxHostCmd | Out-File -Encoding ascii $tempUnmountScript
    Copy-ToControlPlaneViaSSHKey -Source $tempUnmountScript -Target '/home/remote/'
    Remove-Item $tempUnmountScript -ErrorAction Ignore

    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo rm -rf ~/$unmountOnLinuxHostScript").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sed 's/\r//g' ~/$tempUnmountOnLinuxHostScript > ~/$unmountOnLinuxHostScript").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo rm -rf ~/$tempUnmountOnLinuxHostScript").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo chown -R remote /home/remote/$unmountOnLinuxHostScript").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo chmod +x /home/remote/$unmountOnLinuxHostScript").Output | Write-Log

    Write-Log 'Executing on host unmount script inside VM as remote user...'
    ssh.exe -n '-vv' -E $logFile -o StrictHostKeyChecking=no -i $(Get-SSHKeyControlPlane) $(Get-ControlPlaneRemoteUser) "sudo su -s /bin/bash -l -c '~/$unmountOnLinuxHostScript' remote"
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Unmounting '$($Config.LinuxMountPath)' on Linux succeeded."
    }
    else {
        Write-Log "Unmounting '$($Config.LinuxMountPath)' on Linux failed with code '$LASTEXITCODE'."
    }
}

function New-SharedFolderMountOnWindows {
    param (
        [parameter(Mandatory = $false)]
        [pscustomobject]$Config = $(throw 'Config not specified')
    )
    Remove-SmbGlobalMappingIfExisting -RemotePath $Config.LinuxHostRemotePath
    Remove-LocalWinMountIfExisting -Path $Config.WinMountPath
    Remove-MountPointInWindowsIfExisting -RemotePath $Config.LinuxHostRemotePath
    Add-SmbGlobalMappingIfNotExisting -RemotePath $Config.LinuxHostRemotePath -LocalPath $Config.WinMountPath -SmbUser $smbFullUserNameLinux -SmbPasswd $smbPw
    Add-SymLinkOnWindows -RemotePath $Config.LinuxHostRemotePath -LocalPath $Config.WinMountPath
}

function Add-SymLinkOnWindows {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $RemotePath = $(throw 'RemotePath not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $LocalPath = $(throw 'LocalPath not specified')
    )    

    New-Item -ItemType SymbolicLink -Path $LocalPath -Target $RemotePath | Write-Log
    Write-Log "Symbolic Link '$LocalPath --> $RemotePath' created."
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
    $function = $MyInvocation.MyCommand.Name

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
        [parameter(Mandatory = $false)]
        [pscustomobject]$Config = $(throw 'Config not specified'),
        [Parameter(Mandatory = $false)]
        [switch]
        $SkipTest = $false
    )
    $function = $MyInvocation.MyCommand.Name

    Write-Log 'Restoring SMB share (Windows host)..' -Console

    if ($SkipTest -ne $true) {
        Test-SharedFolderMountOnWinNode -Config $Config

        if ($script:Success -eq $True) {
            Write-Log "Access to shared folder '$($Config.WinMountPath)' working, nothing to do"
            return
        }

        Write-Log "No access to shared folder '$($Config.WinMountPath)' yet, establishing it.."
    }

    New-SmbHostOnWindowsIfNotExisting -Config $Config
    New-SharedFolderMountOnLinuxClient -Config $Config
    Wait-ForSharedFolderMountOnLinuxClient -Config $Config
    Test-SharedFolderMountOnWinNode -Config $Config

    if ($script:Success -ne $True) {
        throw "Failed to setup SMB share '$($Config.WinMountPath)' on Windows host"
    }

    Write-Log "Access to shared folder '$($Config.WinMountPath)' working" -Console
}

function New-StorageClassManifest {
    param (
        [parameter(Mandatory = $false)]
        [string]$RemotePath = $(throw 'RemotePath not specified'),
        [parameter(Mandatory = $false)]
        [string]$StorageClassName = $(throw 'StorageClassName not specified')
    )

    $manifestFileName = "$($generatedPrefix)$($StorageClassName).yaml"
    $manifestPath = "$manifestStorageClassesDir\$manifestFileName"

    $templateContent = Get-Content -Path $scTemplateFilePath | Out-String

    Write-Log "StorageClass manifest template '$scTemplateFilePath' loaded"

    $remotePath = Convert-ToUnixPath -Path $RemotePath

    $manifestContent = $templateContent -replace $storageClassNamePlaceholder, $StorageClassName -replace $storageClassSourcePlaceholder, $remotePath

    Set-Content -Value $manifestContent -Path $manifestPath -Force

    Write-Log "StorageClass manifest written to '$manifestPath'."

    return $manifestFileName
}

function Wait-ForPodToBeReady {
    param (
        [Parameter(Mandatory = $false)]
        [int]
        $TimeoutSeconds = 30
    )
    $function = $MyInvocation.MyCommand.Name

    Write-Log "Waiting for Pod to be ready (timeout: $($TimeoutSeconds)s).." -Console

    $ready = Test-CsiPodsCondition -Condition 'Ready' -TimeoutSeconds $TimeoutSeconds

    if ($true -ne $ready) {
        throw "StorageClass not ready within $($TimeoutSeconds)s"
    }

    Write-Log 'StorageClass is ready' -Console
}

function Wait-ForPodToBeDeleted {
    param (
        [Parameter(Mandatory = $false)]
        [int]
        $TimeoutSeconds = 30
    )

    Write-Log " Waiting for Pod to be deleted (timeout: $($TimeoutSeconds)s).." -Console

    $deleted = Test-CsiPodsCondition -Condition 'Deleted' -TimeoutSeconds $TimeoutSeconds

    if ($true -ne $deleted) {
        Write-Log "StorageClass not deleted within $($TimeoutSeconds)s"
        return
    }

    Write-Log 'StorageClass is deleted successfully' -Console
}

function New-StorageClasses {
    param (
        [parameter(Mandatory = $false)]
        [ValidateSet('windows', 'linux')]
        [string]$SmbHostType,
        [parameter(Mandatory = $false)]
        [bool]$LinuxOnly,
        [parameter(Mandatory = $false)]
        [pscustomobject]$Config = $(throw 'Config not specified')
    )     

    $manifestDir = $manifestWinDir
    if ($LinuxOnly -eq $true) {
        $manifestDir = $manifestBaseDir
    }

    Add-Secret -Name $smbCredsName -Namespace $namespace -Literals "username=$smbUserName", "password=$($creds.GetNetworkCredential().Password)" | Write-Log

    $scManifests = [System.Collections.ArrayList]@()

    foreach ($configEntry in $Config) {
        $remotePath = $configEntry.WinHostRemotePath
        if ($SmbHostType -eq 'linux') {
            $remotePath = $configEntry.LinuxHostRemotePath
        }

        $manifest = New-StorageClassManifest -RemotePath $remotePath -StorageClassName $configEntry.StorageClassName
        $scManifests.Add($manifest) | Out-Null
    }

    New-StorageClassKustomization -Manifests $scManifests

    $params = 'apply', '-k', $manifestDir

    Write-Log "Invoking kubectl with '$params'.."

    $result = Invoke-Kubectl -Params $params
    if ($result.Success -ne $true) {
        throw $result.Output
    }

    Wait-ForPodToBeReady -TimeoutSeconds $storageClassTimeoutSeconds
}

function Remove-StorageClasses {
    param (
        [parameter(Mandatory = $false)]
        [bool]$LinuxOnly,
        [parameter(Mandatory = $false)]
        [array]$Config = $(throw 'Config not specified')
    )
    

    $manifestDir = $manifestWinDir
    if ($LinuxOnly -eq $true) {
        $manifestDir = $manifestBaseDir
    }

    foreach ($configEntry in $Config) {
        Remove-PersistentVolumeClaimsForStorageClass -StorageClass $configEntry.StorageClassName | Write-Log
    }

    $params = 'delete', '-k', $manifestDir, '--force', '--ignore-not-found'

    Write-Log "Invoking kubectl with '$params'.."

    $result = Invoke-Kubectl -Params $params
    if ($result.Success -ne $true) {
        Write-Warning "Error occurred while invoking kubectl: $($result.Output)"
        return
    }

    Wait-ForPodToBeDeleted -TimeoutSeconds $storageClassTimeoutSeconds

    Remove-Secret -Name $smbCredsName -Namespace $namespace | Write-Log
}

function New-StorageClassKustomization {
    param (
        [parameter(Mandatory = $false)]
        [System.Collections.ArrayList] $Manifests = $(throw 'Manifests not specified')
    )  

    $manifestPath = "$manifestStorageClassesDir\$scKustomizeFileName"

    $templateContent = Get-Content -Path $scKustomizeTemplateFilePath | Out-String

    Write-Log "StorageClass Kustomize manifest template '$scKustomizeTemplateFilePath' loaded"

    $manifestContent = $templateContent -replace $kustomizeResourcesPlaceholder, ($Manifests -join ',')
    
    Set-Content -Value $manifestContent -Path $manifestPath -Force

    Write-Log "StorageClass Kustomize manifest written to '$manifestPath'."
}

<#
    .SYNOPSIS
        Calls Resolve-Path but works for files that don't exist.
#>
function Expand-PathSMB {
    param (
        [parameter(Mandatory = $false)]
        [string] $FilePath = $(throw 'FilePath not specified')
    )
    $verifiedPath = Resolve-Path $FilePath -ErrorAction SilentlyContinue -ErrorVariable _frperror
    if (-not($verifiedPath)) {
        return $_frperror[0].TargetObject
    }
    return $verifiedPath
}

function Remove-SmbShareAndFolderWindowsHost {
    param (
        [parameter(Mandatory = $false)]
        [pscustomobject]$Config = $(throw 'Config not specified'),
        [parameter(Mandatory = $false)]
        [switch]$SkipNodesCleanup = $false,
        [parameter(Mandatory = $false)]
        [switch]$Keep = $false
    )    

    Write-Log 'Removing SMB shares and folders hosted on Windows..'

    if ($SkipNodesCleanup -ne $true) {
        Remove-SharedFolderMountOnLinuxClient -Config $Config -Keep:$Keep
    }

    Remove-SmbHostOnWindowsIfExisting -Config $Config -Keep:$Keep
}

function Restore-SmbShareAndFolderLinuxHost {
    param (
        [parameter(Mandatory = $false)]
        [pscustomobject]$Config = $(throw 'Config not specified'),
        [Parameter(Mandatory = $false)]
        [switch]$SkipTest = $false
    )    

    Write-Log 'Restoring SMB share (Linux Samba host)..' -Console

    if ($SkipTest -ne $true) {
        Wait-ForSharedFolderOnLinuxHost -Config $Config

        if ($script:Success -eq $true) {
            Write-Log 'Samba share on Linux already working, checking mount on Windows node..'
            Test-SharedFolderMountOnWinNode -Config $Config
        }

        if ($script:Success -eq $true) {
            Write-Log "Access to shared folder '$($Config.LinuxMountPath)' working, nothing to restore."
            return
        }

        Write-Log "No access to shared folder '$($Config.LinuxMountPath)', establishing it.." -Console
    }

    New-SmbHostOnLinuxIfNotExisting -Config $Config
    New-SharedFolderMountOnLinuxHost -Config $Config
    Wait-ForSharedFolderOnLinuxHost -Config $Config

    if ($script:Success -ne $true) {
        throw 'Unable to mount shared folder with CIFS on Linux host'
    }

    Write-Log 'SMB share hosted and mounted on Linux, creating mount on Windows node..' -Console

    New-SharedFolderMountOnWindows -Config $Config

    Test-SharedFolderMountOnWinNode -Config $Config

    if ($script:Success -ne $true) {
        throw "Unable to setup SMB share '$($Config.LinuxMountPath)' on Linux host"
    }

    Write-Log "Access to shared folder '$($Config.LinuxMountPath)' working" -Console
}

function Remove-SmbShareAndFolderLinuxHost {
    param (
        [parameter(Mandatory = $false)]
        [pscustomobject]$Config = $(throw 'Config not specified'),
        [parameter(Mandatory = $false)]
        [switch]$SkipNodesCleanup = $false,
        [parameter(Mandatory = $false)]
        [switch]$Keep = $false
    )   

    Write-Log 'Removing SMB shares and folders hosted on Linux..'

    Remove-SmbGlobalMappingIfExisting -RemotePath $Config.LinuxHostRemotePath
    Remove-LocalWinMountIfExisting -Path $Config.WinMountPath -Keep:$Keep
    Remove-MountPointInWindowsIfExisting -RemotePath $Config.LinuxHostRemotePath

    if ($SkipNodesCleanup -ne $true) {
        Remove-SharedFolderMountOnLinuxHost -Config $Config -Keep:$Keep
        Remove-SmbHostOnLinux -LinuxShareName $Config.LinuxShareName -Keep:$Keep
    }
}

function Remove-SmbShareAndFolder() {
    param (
        [parameter(Mandatory = $false)]
        [pscustomobject]$Config = $(throw 'Config not specified'),
        [parameter(Mandatory = $false)]
        [switch]$SkipNodesCleanup = $false,
        [parameter(Mandatory = $false)]
        [switch]$Keep = $false  
    )    

    Write-Log 'Removing SMB shares and folders..' -Console    

    $smbHostType = Get-SmbHostType

    switch ($SmbHostType) {
        'windows' {
            Remove-SmbShareAndFolderWindowsHost -SkipNodesCleanup:$SkipNodesCleanup -Config $Config -Keep:$Keep
        }
        'linux' {
            Remove-SmbShareAndFolderLinuxHost -SkipNodesCleanup:$SkipNodesCleanup -Config $Config -Keep:$Keep
        }
        Default {
            throw "invalid SMB host type '$SmbHostType'"
        }
    }
}

function Remove-TempManifests {
    Get-ChildItem -File -Path "$manifestStorageClassesDir\*" -Include "$generatedPrefix*", $scKustomizeFileName | Remove-Item -Force -ErrorAction SilentlyContinue
}

function Test-SharedFolderMountOnWinNode {
    param (
        [parameter(Mandatory = $false)]
        [pscustomobject]$Config = $(throw 'Config not specified'),
        [Parameter(Mandatory = $false)]
        [switch]
        $Nested = $false
    )
    
    Write-Log 'Checking shared folder on Windows node..'
    $script:Success = $false

    if (!(Test-Path -path $Config.WinMountPath -PathType Container)) {
        return
    }

    $testFileName = 'accessTest.flag'
    $winTestFile = "$($Config.WinMountPath)\$testFileName"
    $linuxTestFile = "$($Config.LinuxMountPath)/$testFileName"

    if (Test-Path $winTestFile) {
        Remove-Item -Force $winTestFile -ErrorAction Stop
    }

    Write-Log "Create test file on linux side: $linuxTestFile"
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "test -d $($Config.LinuxMountPath) && sudo touch $linuxTestFile" -Nested:$Nested -Retries 10).Output | Write-Log

    $iteration = 15
    while ($iteration -gt 0) {
        $iteration--
        if (Test-Path $winTestFile) {
            Write-Log " Remove test file on windows side: $winTestFile"
            Remove-Item -Force $winTestFile -ErrorAction SilentlyContinue

            $script:Success = $true
            return
        }
        Start-Sleep 2
    }
    Write-Log "Not accessable through windows, removing test file on linux side: $linuxTestFile ..."
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "test -d $($Config.LinuxMountPath) && sudo rm -f $linuxTestFile" -NoLog -Nested:$Nested).Output | Write-Log
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
    $systemError = Test-SystemAvailability -Structured
    if ($systemError) {
        return @{Error = $systemError }
    }

    if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = $AddonName })) -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message "Addon '$AddonName' is already enabled, nothing to do." 
        return @{Error = $err }
    }

    $setupInfo = Get-SetupInfo

    if ($setupInfo.Name -ne 'k2s') {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon '$AddonName' can only be enabled for 'k2s' setup type."  
        return @{Error = $err }
    }

    Copy-ScriptsToHooksDir -ScriptPaths @(Get-ChildItem -Path $localHooksDir | ForEach-Object { $_.FullName })

    $rawStorageConfig = @(Get-StorageConfig -Raw)

    Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = $AddonName; Implementation = $ImplementationName; SmbHostType = $SmbHostType; Storage = $rawStorageConfig })

    $storageConfig = Get-StorageConfigFromRaw -RawConfig $rawStorageConfig

    foreach ($storageEntry in $storageConfig) {
        Restore-SmbShareAndFolder -SmbHostType $SmbHostType -SkipTest -Config $storageEntry        
    }

    New-SmbShareNamespace
    New-StorageClasses -SmbHostType $SmbHostType -LinuxOnly $setupInfo.LinuxOnly -Config $storageConfig

    Write-Log -Console '********************************************************************************************'
    Write-Log -Console '** IMPORTANT                                                                              **' 
    Write-Log -Console '********************************************************************************************'
    Write-Log -Console '** Use the following StorageClass name(s) that correspond to your SMB storage config:     **'
    
    foreach ($sc in $storageConfig.storageClassName) {
        Write-Log -Console "    -> $($sc)"
    }
    
    Write-Log -Console '**                                                                                        **'
    Write-Log -Console "** See '<root>\k2s\test\e2e\addons\storage\smb\workloads\' for example deployments.       **"
    Write-Log -Console '********************************************************************************************'

    return @{Error = $null }
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
        [switch]$SkipNodesCleanup = $false,
        [parameter(Mandatory = $false)]
        [switch]$Keep = $false        
    )    

    if ($SkipNodesCleanup -eq $true) {
        Write-Log 'Skipping SMB share cleanup on VMs..'
    }
    else {
        $systemError = Test-SystemAvailability -Structured
        if ($systemError) {
            return @{Error = $systemError }
        }
    }

    if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = $AddonName })) -ne $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyDisabled) -Message "Addon '$AddonName $ImplementationName' is already disabled, nothing to do."
        return @{Error = $err }
    }

    Write-Log " Disabling '$AddonName'.."

    $setupInfo = Get-SetupInfo
    $storageConfig = Get-StorageConfig

    if ($SkipNodesCleanup -ne $true) {
        Remove-StorageClasses -LinuxOnly $setupInfo.LinuxOnly -Config $storageConfig   
        Remove-SmbShareNamespace 
    }

    Remove-TempManifests

    foreach ($storageEntry in $storageConfig) {
        Remove-SmbShareAndFolder -SkipNodesCleanup:$SkipNodesCleanup -Config $storageEntry -Keep:$Keep        
    }   

    Remove-AddonFromSetupJson -Addon ([pscustomobject] @{Name = $AddonName; Implementation = $ImplementationName })
    Remove-ScriptsFromHooksDir -ScriptNames @(Get-ChildItem -Path $localHooksDir | ForEach-Object { $_.Name })
   
    return @{Error = $null }
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

.PARAMETER Config
SMB share configuration
#>
function Restore-SmbShareAndFolder {
    param (
        [parameter(Mandatory = $false)]
        [ValidateSet('windows', 'linux')]
        [string]$SmbHostType,
        [parameter(Mandatory = $false)]
        [pscustomobject]$Config = $(throw 'Config not specified'),
        [parameter(Mandatory = $false)]
        [switch]$SkipTest = $false
    )
    switch ($SmbHostType) {
        'windows' {
            Restore-SmbShareAndFolderWindowsHost -SkipTest:$SkipTest -Config $Config
        }
        'linux' {
            Restore-SmbShareAndFolderLinuxHost -SkipTest:$SkipTest -Config $Config
        }
        Default {
            throw "invalid SMB host type '$SmbHostType'"
        }
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

function Get-Status {
    $setupInfo = Get-SetupInfo

    if ($setupInfo.Error) {
        throw $setupInfo.Error
    }
    # validate setup type for SMB share as well
    if ($setupInfo.Name -ne 'k2s') {
        throw "Cannot determine if SMB shares are working for invalid setup type '$($setupInfo.Name)'"
    }

    $storageConfig = Get-StorageConfig

    $props = [System.Collections.ArrayList]@()

    $smbHostTypeProp = @{Name = 'SmbHostType'; Value = Get-SmbHostType }

    $props.Add($smbHostTypeProp) | Out-Null

    foreach ($configEntry in $storageConfig) {
        Test-SharedFolderMountOnWinNode -Config $configEntry | Out-Null

        $isSmbShareWorkingProp = @{Name = "ShareForStorageClass_$($configEntry.StorageClassName)"; Value = $script:Success; Okay = $script:Success }
        if ($isSmbShareWorkingProp.Value -eq $true) {
            $isSmbShareWorkingProp.Message = "The SMB share is working, path: ($($configEntry.WinMountPath) <-> $($configEntry.LinuxMountPath))"
        }
        else {
            $isSmbShareWorkingProp.Message = "The SMB share is not working ($($configEntry.WinMountPath) <-> $($configEntry.LinuxMountPath)). Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable $AddonName $ImplementationName' and 'k2s addons enable $AddonName $ImplementationName'"
        }
        $props.Add($isSmbShareWorkingProp) | Out-Null
    }
    
    $areCsiPodsRunning = Test-CsiPodsCondition -Condition 'Ready'

    $areCsiPodsRunningProp = @{Name = 'AreCsiPodsRunning'; Value = $areCsiPodsRunning; Okay = $areCsiPodsRunning }
    if ($areCsiPodsRunningProp.Value -eq $true) {
        $areCsiPodsRunningProp.Message = 'The CSI Pods are running'
    }
    else {
        $areCsiPodsRunningProp.Message = "The CSI Pods are not running. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable $AddonName $ImplementationName' and 'k2s addons enable $AddonName $ImplementationName'"
    }

    $props.Add($areCsiPodsRunningProp) | Out-Null

    return $props
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

    $AddonDirName = "$AddonName-$ImplementationName"
    $BackupDir = "$BackupDir\$AddonDirName"

    if ((Test-Path $BackupDir) -ne $true) {
        Write-Log "'$AddonDirName' backup dir not existing, creating it.."
        New-Item -Path $BackupDir -ItemType Directory -Force | Out-Null
    }

    $config = Get-StorageConfig
    $mountPaths = @($config.WinMountPath)

    Write-Log "Copying data from '$mountPaths' to '$BackupDir'.."

    for ($i = 0; $i -lt $mountPaths.Count; $i++) {
        Copy-Item -Path $mountPaths[$i] -Destination "$BackupDir\$(Split-Path -Path $mountPaths[$i] -Leaf)_$i" -Force -Recurse
    }

    Write-Log "Data copied to '$BackupDir'."  
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

    $AddonDirName = "$AddonName-$ImplementationName"
    $BackupDir = "$BackupDir\$AddonDirName"

    if ((Test-Path $BackupDir) -ne $true) {
        Write-Log "'$AddonDirName' backup dir not existing, skipping."
        return
    }

    $config = Get-StorageConfig
    $mountPaths = $config.WinMountPath

    for ($i = 0; $i -lt $mountPaths.Count; $i++) {
        $target = $mountPaths[$i]

        Write-Log "Copying data from '$BackupDir' to '$target'.."

        Copy-Item -Path "$BackupDir\$(Split-Path -Path $mountPaths[$i] -Leaf)_$i\*" -Destination $mountPaths[$i] -Force -Recurse

        Write-Log "Data copied to '$target'."
    }
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

.PARAMETER Path
The Windows mount path

.NOTES
This function can be imported and executed on a Win VM node
#>
function Remove-LocalWinMountIfExisting {
    param (
        [parameter(Mandatory = $false)]
        [string]$Path = $(throw 'Path not specified'),
        [parameter(Mandatory = $false)]
        [switch]$Keep = $false
    )    

    if ((Test-Path -Path $Path) -ne $true) {
        Write-Log 'Windows mount not existing, nothing to remove.'
        return
    }

    $winMount = Get-Item $Path
    if ( ($winMount | Select-Object -Property LinkType).LinkType -eq 'SymbolicLink') {
        $winMount.Delete()

        Write-Log "SymbolicLink '$Path' deleted."
    }
    else {
        if ($Keep -eq $true) {
            Write-Log "Directory '$Path' kept."
            return
        }
        Remove-Item $Path -Recurse -Force
        Write-Log "Directory '$Path' deleted."
    }
}

function New-SmbShareNamespace {
    
    $params = 'create', 'namespace', $namespace
    Write-Log "Invoking kubectl with '$params'.."
    $result = Invoke-Kubectl -Params $params
    if ($result.Success -ne $true) {
        throw $result.Output
    }
}

function Remove-SmbShareNamespace {    

    $params = 'delete', 'namespace', $namespace, '--ignore-not-found=true'
    Write-Log "Invoking kubectl with '$params'.."
    $result = Invoke-Kubectl -Params $params
    if ($result.Success -ne $true) {
        throw $result.Output
    }
}

function Get-StorageConfigPath {
    return $configFilePath    
}

function Get-StorageConfig {
    param (       
        [parameter(Mandatory = $false)]
        [switch]$Raw = $false
    )    
    
    $configPath = Get-StorageConfigPath
    
    Write-Log "Loading storage config '$configPath'"

    if (!(Test-Path $configPath)) {
        throw "Storage config file '$configPath' not found"
    }    

    # TODO: validate config, e.g. unique value, existing paths, naming conventions, etc.?
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    if (-not $config) {
        throw "Storage config file '$configPath' empty or invalid"
    }

    if ($Raw -eq $true) {
        return @($config)
    }
    return @(Get-StorageConfigFromRaw -RawConfig $config)
}

function Get-StorageConfigFromRaw {
    param (       
        [parameter(Mandatory = $false)]
        [array]$RawConfig = $(throw 'RawConfig not specified')
    )
    return @($RawConfig | ForEach-Object {
            $winMountPath = Expand-PathSMB -FilePath $_.winMountPath
            $linuxShareName = Split-Path -Path $_.linuxMountPath -Leaf
            $winShareName = Split-Path -Path $winMountPath -Leaf

            [pscustomobject]@{
                StorageClassName    = $_.storageClassName
                LinuxMountPath      = $_.linuxMountPath
                WinMountPath        = $winMountPath
                LinuxShareName      = $linuxShareName
                WinShareName        = $winShareName
                LinuxHostRemotePath = "\\$(Get-ConfiguredIPControlPlane)\$linuxShareName"
                WinHostRemotePath   = "\\$(Get-ConfiguredKubeSwitchIP)\$winShareName"
            }
        }   
    )
}

<#
.SYNOPSIS
Removes the mount point on windows side because it is not needed anymore

.DESCRIPTION
Removes the mount point on windows side because it is not needed anymore

.PARAMETER RemotePath
The SMB share remote path

.NOTES
This function can be imported
#>
function Remove-MountPointInWindowsIfExisting {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $RemotePath = $(throw 'RemotePath not specified')
    )    

    Write-Log "Removing mount point to '$RemotePath'.."
    &net use $RemotePath /delete >$null 2>&1
    Write-Log "Mount point to '$RemotePath' removed."
}

Export-ModuleMember -Function Enable-SmbShare, Disable-SmbShare, Restore-SmbShareAndFolder,
Get-SmbHostType, Get-StorageConfig, Get-Status, Backup-AddonData, Get-StorageConfigPath, Get-StorageConfigFromRaw,
Restore-AddonData, Remove-SmbGlobalMappingIfExisting, Remove-MountPointInWindowsIfExisting, Remove-LocalWinMountIfExisting -Variable AddonName

