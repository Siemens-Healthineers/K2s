# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

$pathModule = "$PSScriptRoot\..\..\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\k2s.infra.module\log\log.module.psm1"
$vmnodeModule = "$PSScriptRoot\..\..\k2s.node.module\vmnode\vmnode.module.psm1"
Import-Module $pathModule, $logModule, $vmnodeModule

$rootConfig = Get-RootConfig

$multivmRootConfig = $rootConfig.psobject.properties['multivm'].value
# Password for Linux/Windows VMs during installation
$vmPwd = 'admin'

function Get-RootConfigMultivm {
    return $multivmRootConfig
}

function Initialize-WinVM {
    Param(
        [parameter(Mandatory = $true, HelpMessage = 'Windows VM Name to use')]
        [string] $Name,
        [parameter(Mandatory = $false, HelpMessage = 'Windows Image to use')]
        [string] $Image,
        [parameter(Mandatory = $false, HelpMessage = 'Windows OS version to use (if no Image is set)')]
        [string] $OsVersion,
        [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of VM')]
        [long] $VMStartUpMemory = 8GB,
        [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of VM')]
        [long] $VMDiskSize = 100GB,
        [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for VM')]
        [long] $VMProcessorCount = 4,
        [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
        [string] $Proxy,
        [parameter(Mandatory = $false, HelpMessage = 'Enable if virtio drivers should be added')]
        [switch] $VirtioDrivers,
        [parameter(Mandatory = $false, HelpMessage = 'Generation of the VM, can be 1 or 2')]
        [ValidateRange(1, 2)]
        [int16] $Generation = 2,
        [parameter(Mandatory = $false, HelpMessage = 'DNS Addresses if available')]
        [string[]]$DnsAddresses = @('8.8.8.8', '8.8.4.4'),
        [parameter(Mandatory = $false, HelpMessage = "Type of VM Setup, 'Dev' will install all components")]
        [ValidateSet('Basic', 'Dev')] #experimental
        [string] $VMEnv = 'Basic',
        [parameter(Mandatory = $false, HelpMessage = 'Enable proxy in VM')]
        [switch] $DontSetProxyInVM = $false,
        [Parameter(Mandatory = $false)]
        [string]$Edition,
        [parameter(Mandatory = $false, HelpMessage = 'Name of the switch to use/create')]
        [string] $SwitchName = '',
        [parameter(Mandatory = $false, HelpMessage = 'IP address of the switch to use/create')]
        [string] $SwitchIP = '',
        [parameter(Mandatory = $false, HelpMessage = 'Create a switch with the given name, if TRUE.')]
        [bool] $CreateSwitch = $true,
        [parameter(Mandatory = $false, HelpMessage = 'IP address to assign to the VM. If none is defined, an IP address will be determined automatically.')]
        [string] $IpAddress,
        [parameter(Mandatory = $false, HelpMessage = 'Locale of the Windows Image, ensure the iso supplied has the locale')]
        [string]$Locale = 'en-US'
    )

    $ErrorActionPreference = 'Continue'
    # check name
    if ($Name.length -gt 15) {
        Write-Log 'Name is to long. It must be less or equal than 15 characters. !'
        throw 'Name check'
    }

    # check memory
    if ($VMStartUpMemory -lt 2GB) {
        Write-Log 'Main memory must be higher than 2GB !'
        throw 'Memory check'
    }

    # check disk size
    if ($VMDiskSize -lt 20GB) {
        Write-Log 'Disk size must be higher than 20GB !'
        throw 'Disk size check'
    }

    # check processors
    if ($VMProcessorCount -lt 4) {
        Write-Log 'Processors must be more than 3 !'
        throw 'Processors check'
    }

    # check other parameters
    if (! $Image ) {
        if (! $OsVersion ) {
            Write-Log 'Image or OsVersion needs to be specified !'
            throw 'Image and OsVersion check'
        }
    }

    if (! (Test-Path $Image)) {
        throw "Missing VM ISO image: $Image"
    }

    # set default values for switch
    if ($SwitchName -eq '') {
        $SwitchName = 'k2sSetup'
    }
    if ($SwitchIP -eq '') {
        $SwitchIP = '172.29.29.1'
    }

    $giturlk = 'https://github.com/Siemens-Healthineers/K2s.git'
    Write-Log "Git url for k: $giturlk"

    # check prerequisites
    $virtualizedNetworkCIDR = '172.29.29.0/24'
    $virtualizedNAT = 'k2sSetup'

    if ($CreateSwitch -eq $true) {
        # try to create switch
        $swtype = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty SwitchType
        if ( $swtype -eq 'Private') {
            Write-Log "Switch: $SwitchName is corrupted, try to delete it"
            throw "Hyper-V switch $SwitchName is corrupted, please delete it in Hyper-V Manager (before disconnect all VMs from it), do a k2s uninstall and start from scratch !"
        }

        Write-Log "Try to find switch: $SwitchName"
        $sw = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
        if ( !($sw) ) {
            Write-Log "Switch not found: $SwitchName"
            # create new switch
            Write-Log "Create internal switch: $SwitchName and NAT: $virtualizedNAT"
            New-VMSwitch -Name $SwitchName -SwitchType Internal -MinimumBandwidthMode Weight | Out-Null
        }

        Write-Log "Check ip address $SwitchIP"
        $netip = Get-NetIPAddress -IPAddress $SwitchIP -ErrorAction SilentlyContinue
        if ( !($netip) ) {
            Write-Log 'IP address for switch, recreate it'
            New-NetIPAddress -IPAddress $SwitchIP -PrefixLength 24 -InterfaceAlias "vEthernet ($SwitchName)" | Out-Null
        }

        Write-Log "Check NAT $virtualizedNAT"
        $nat = Get-NetNat -Name $virtualizedNAT -ErrorAction SilentlyContinue
        if ( !($nat) ) {
            Write-Log "NAT not found: $virtualizedNAT, recreate it"
            New-NetNat -Name $virtualizedNAT -InternalIPInterfaceAddressPrefix $virtualizedNetworkCIDR -ErrorAction SilentlyContinue | Out-Null
        }

        # route for VM
        Write-Log "Remove obsolete route to $virtualizedNetworkCIDR"
        route delete $virtualizedNetworkCIDR >$null 2>&1
        Write-Log "Add route to $virtualizedNetworkCIDR"
        route -p add $virtualizedNetworkCIDR $SwitchIP METRIC 8 | Out-Null
    }

    # download virtio image
    $virtioImgFile = ''
    if ( ($VirtioDrivers) ) {
        Write-Log 'Start to download virtio image ...'
        $virtioImgFile = Get-VirtioImage -Proxy "$Proxy"
        Write-Log "Virtio image: $virtioImgFile"
    }

    # check edition
    if ($Edition -eq '') {
        $Edition = 'Windows 10 Pro'
    }

    # install vm where we would run the small k8s setup
    Write-Log "Create VM $Name"
    Write-Log "Using $VMStartUpMemory of memory for VM"
    Write-Log "Using $VMDiskSize of virtual disk space for VM"
    Write-Log "Using $VMProcessorCount of virtual processor count for VM"
    Write-Log "Using image: $Image"
    Write-Log "Using virtio image: $virtioImgFile"
    Write-Log "Using generation: $Generation"
    Write-Log "Using edition: $Edition"
    Write-Log "Using locale: $Locale"

    New-VMFromWinImage -ImgDir $Image `
        -WinEdition $Edition `
        -Name $Name `
        -AdminPwd $vmPwd `
        -Version 'Windows10Professional' `
        -VMMemoryInBytes $VMStartUpMemory `
        -VMVHDXSizeInBytes $VMDiskSize `
        -VMProcessorCount $VMProcessorCount `
        -VMSwitchName $SwitchName `
        -AddVirtioDrivers $virtioImgFile `
        -Locale $Locale `
        -Generation $Generation

    Write-Log "Using '$VMEnv' setup for created VM"

    # get current timezone
    $timezone = tzutil /g
    Write-Log "Host time zone '$timezone' .."

    if (! $IpAddress) {
        # get next ip address available
        $NextIpAddress = ''
        $iRange = 1;
        while ($iRange -lt 256) {
            $NextIpAddress = $virtualizedNetworkCIDR.replace('0/24', $iRange)
            Write-Log "IP Address: $NextIpAddress"
            $bTest = Test-Connection -ComputerName $NextIpAddress -Count 1 -Quiet
            if ( !($bTest) ) { break }
            $iRange++;
        }

        $IpAddress = $NextIpAddress
    }

    # set IP address
    $session1 = Open-RemoteSession -VmName $Name -VmPwd $vmPwd
    Write-Log "Set ip address: $IpAddress"
    Set-VmIPAddress -PSSession $session1 -IPAddr $IpAddress -DefaultGatewayIpAddr $SwitchIP -DnsAddr $DnsAddresses -MaskPrefixLength 24

    Write-Log "Enable windows features in VM $Name"
    Invoke-Command -Session $session1 {
        Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart -WarningAction silentlyContinue
        Enable-WindowsOptionalFeature -Online -FeatureName containers -All -NoRestart -WarningAction silentlyContinue
        Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart -WarningAction silentlyContinue
    }

    Write-Log 'Sync time zone of VM with host'
    Invoke-Command -Session $session1 {
        #Set timezone in VM
        tzutil /s $using:timezone
        Write-Output "Completed setting time zone: $using:timezone"

        Write-Output 'Check Host machine Keyboard layout ...'
        Add-Type -AssemblyName System.Windows.Forms
        $lang = [System.Windows.Forms.InputLanguage]::CurrentInputLanguage
        Write-Output "Found Keyboard on Host: '$($lang.LayoutName)' ..."
        if ( $lang.LayoutName -eq 'German') {
            $langList = Get-WinUserLanguageList
            # Remove the default US keyboard
            $langList[0].InputMethodTips.Clear()
            # Add the German keyboard
            $langList[0].InputMethodTips.Add('0409:00000407')
            # Force the changes
            Set-WinUserLanguageList $langList -Force

            # Add the English keyboard after forcing German keyboard layout
            $langList[0].InputMethodTips.Add('0409:00000409')
            # Force the changes again
            Set-WinUserLanguageList $langList -Force
        }
    }

    # Write-Output "Disconnect session"
    # Disconnect-PSSession -Session $session

    $session2 = Open-RemoteSession -VmName $Name -VmPwd $vmPwd

    # install other components needed in VM
    Invoke-Command -Session $session2 -WarningAction SilentlyContinue {
        Write-Output 'Change network policy'
        Get-NetConnectionprofile | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue

        Write-Output 'Install choco and additional packages ...'

        $attempts = 0
        $MaxAttempts = 3
        $RetryIntervalInSeconds = 5

        while ($attempts -lt $MaxAttempts) {
            try {

                Set-ExecutionPolicy Bypass -Scope Process -Force -ErrorAction SilentlyContinue
                [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072

                if ($using:Proxy) {
                    Write-Output 'Installing choco using Proxy ...'
                    [system.net.webrequest]::defaultwebproxy = New-Object system.net.webproxy($using:Proxy)
                    Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://chocolatey.org/install.ps1')) 3>&1
                    choco config set proxy $using:Proxy
                }
                else {
                    Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://chocolatey.org/install.ps1')) 3>&1
                }
                break
            }
            catch {
                Write-Output "Attempt $($attempts + 1) failed with error: $($_.Exception.Message)"
                $attempts++

                if ($attempts -eq $MaxAttempts) {
                    throw "Unable to download chocolatey, error: $_"
                }

                Start-Sleep -Seconds $RetryIntervalInSeconds
            }
        }

    }

    Invoke-Command -Session $session2 -ErrorAction SilentlyContinue {
        choco feature enable -n=allowGlobalConfirmation | Out-Null
        choco feature enable -n=logWithoutColor | Out-Null
        choco feature disable -n=logValidationResultsOnWarnings | Out-Null
        choco feature disable -n=showDownloadProgress | Out-Null
        choco feature disable -n=showNonElevatedWarnings | Out-Null

        if ($using:VMEnv -eq 'Dev') {
            Write-Output 'Install code and golang'
            choco install vscode | Out-Null
            choco install golang | Out-Null
        }

        choco install nssm | Out-Null

        Write-Output 'Install git'
        choco install git.install | Out-Null

        Write-Output 'Install kubernetes cli'
        choco install kubernetes-cli | Out-Null

        Write-Output 'Install open ssh'
        choco install openssh --pre | Out-Null
        New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' -Group 'k2s' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
        &powershell 'C:\Program` Files\OpenSSH-Win64\install-sshd.ps1' | Out-Null

        Write-Output 'Install Powershell 7'
        choco install powershell-core --version=7.3.4 -Force

        Write-Output 'Choco packages done'
    }

    #Sync host git version with windows Node
    #1. Check for git tags
    #2. Check for last commmit on host
    #3. TBD Offline

    $currentGitCommitHash = git log --format="%H" -n 1
    $finalGitCheckout = ''

    if ($currentGitCommitHash) {
        Write-Log "Using commit hash for checkout $currentGitCommitHash"
        $finalGitCheckout = $currentGitCommitHash
    }
    else {
        $finalGitCheckout = 'main'
    }

    $currentGitUserName = git config --get user.name
    $currentGitUserEmail = git config --get user.email

    Write-Log 'Download Small K8s Setup'
    Invoke-Command -Session $session2 -ErrorAction SilentlyContinue {
        New-Item -ItemType Directory -Force c:\k
        Set-Location $env:SystemDrive\k
        if ($using:Proxy) {
            Write-Output 'Configuring Proxy for git'
            &'C:\Program Files\Git\cmd\git.exe' config --global http.proxy $using:Proxy
        }

        Write-Output "Clone respository: $using:giturlk"
        &'C:\Program Files\Git\cmd\git.exe' clone $using:giturlk c:\k

        Write-Output "Checking out '$using:finalGitCheckout' ..."
        &'C:\Program Files\Git\cmd\git.exe' checkout $using:finalGitCheckout
        &'C:\Program Files\Git\cmd\git.exe' log --pretty=oneline -n 1

        if ($using:VMEnv -eq 'Dev') {
            # Configure host git user name and email for Dev setup
            if (! (git config --get user.name)) {
                Write-Output "Configuring user.name for git with: $currentGitUserName"
                &'C:\Program Files\Git\cmd\git.exe' config --global user.name $currentGitUserName
            }

            if (! (git config --get user.email)) {
                Write-Output "Configuring user.email for git with: $currentGitUserEmail"
                &'C:\Program Files\Git\cmd\git.exe' config --global user.email $currentGitUserEmail
            }
        }
    }

    $session4 = Open-RemoteSession -VmName $Name -VmPwd $vmPwd

    $pr = ''
    if ( $Proxy ) { $pr = $Proxy.Replace('http://', '') }

    Invoke-Command -Session $session4 {
        Set-Location $env:SystemDrive\k
        Set-ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue

        Import-Module $env:SystemDrive\k\lib\modules\k2s.infra.module\k2s.infra.module.psm1
        Import-Module $env:SystemDrive\k\lib\modules\k2s.node.module\k2s.node.module.psm1
        Initialize-Logging -Nested:$true

        Write-Output 'Proxy settings, network discovery off'
        if ($using:Proxy -and !$using:DontSetProxyInVM) {
            Write-Output "Simple proxy: $using:pr"
            netsh winhttp set proxy proxy-server=$using:pr bypass-list="<local>"
            $RegKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
            Set-ItemProperty -Path $RegKey ProxyEnable -Value 1 -Verbose -ErrorAction Stop
            Set-ItemProperty -Path $RegKey ProxyServer -Value $using:pr -verbose -ErrorAction Stop
        }

        # network discovery off
        reg ADD HKLM\SYSTEM\CurrentControlSet\Control\Network\NewNetworkWindowOff /f

        # add parts to path
        Update-SystemPath -Action 'add' 'c:\k\bin'
        Update-SystemPath -Action 'add' 'c:\k\bin\docker'

        # create shell shortcut
        $WshShell = New-Object -comObject WScript.Shell
        $Shortcut = $WshShell.CreateShortcut("$Home\Desktop\cmd.lnk")
        $Shortcut.TargetPath = 'C:\Windows\System32\cmd.exe'
        $Shortcut.Arguments = "/K `"cd c:\k`""
        $Shortcut.Save()

        # Stop automatic updates
        reg Add 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' /V 'NoAutoUpdate' /T REG_DWORD /D '1' /F

        # ignore update for other OS types
        if ( $using:OsVersion ) {
            reg Add 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' /V 'TargetReleaseVersion' /T REG_DWORD /D '1' /F
            reg Add 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' /V 'TargetReleaseVersionInfo' /T REG_SZ /D $using:OsVersion /F
        }

        # Stop Microsoft Defender interference with K2s setup
        Add-K2sToDefenderExclusion

        # enable RDP
        Write-Log 'Enable RDP'
        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -name 'fDenyTSConnections' -value 0
        Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'
    }

    Write-Log 'Restart VM'
    Stop-VM -Name $Name -Force
    # enable nested virtualization
    $virt = Get-CimInstance Win32_Processor | where { ($_.Name.Contains('Intel')) }
    if ( $virt ) {
        Write-Log 'Enable nested virtualization'
        Set-VMProcessor -VMName $Name -ExposeVirtualizationExtensions $true
    }
    Start-VM -Name $Name

    $session5 = Open-RemoteSession -VmName $Name -VmPwd $vmPwd

    Invoke-Command -Session $session5 -WarningAction SilentlyContinue {
        Set-Location $env:SystemDrive\k
        Set-ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory "c:\k\lib\NSSM"
        Copy-Item -Path 'C:\ProgramData\chocolatey\lib\NSSM\*' -Destination "c:\k\lib\NSSM" -Recurse -Force
        Copy-Item -Path 'C:\ProgramData\chocolatey\bin\nssm.exe' -Destination "c:\k\bin" -Force

        Set-Service -Name sshd -StartupType Automatic
        Start-Service sshd
        nssm status sshd

        REG ADD 'HKLM\SYSTEM\CurrentControlSet\Control\Windows Containers' /v SkipVersionCheck /t REG_DWORD /d 2 /f
    }

    # all done
    Write-Log "All steps done, VM $Name now available !"
}

function Initialize-WinVMNode {
    Param(
        [parameter(Mandatory = $true, HelpMessage = 'Kubernetes version to use')]
        [string] $KubernetesVersion,
        [parameter(Mandatory = $false, HelpMessage = 'Host machine is a VM: true, Host machine is not a VM')]
        [bool] $HostVM = $false,
        [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
        [string] $Proxy = '',
        [parameter(Mandatory = $true, HelpMessage = 'Host-GW or VXLAN, Host-GW: true, false for vxlan')]
        [bool] $HostGW,
        [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
        [boolean] $DeleteFilesForOfflineInstallation = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Force the installation online. This option is needed if the files for an offline installation are available but you want to recreate them.')]
        [boolean] $ForceOnlineInstallation = $false
    )

    $session = Open-RemoteSession -VmName $Name -VmPwd $vmPwd

    Initialize-SSHConnectionToWinVM $session

    Initialize-PhysicalNetworkAdapterOnVM $session

    Repair-WindowsAutoConfigOnVM $session

    Restart-VM $Name
    $session = Open-RemoteSession -VmName $Name -VmPwd $vmPwd

    Invoke-Command -Session $session {
        Set-Location "$env:SystemDrive\k"
        Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

        Import-Module $env:SystemDrive\k\lib\modules\k2s.infra.module\k2s.infra.module.psm1
        Import-Module $env:SystemDrive\k\lib\modules\k2s.node.module\k2s.node.module.psm1
        Initialize-Logging -Nested:$true

        Initialize-WinNode -KubernetesVersion $using:KubernetesVersion `
            -HostGW:$using:HostGW `
            -HostVM:$using:HostVM `
            -Proxy:"$using:Proxy" `
            -DeleteFilesForOfflineInstallation $using:DeleteFilesForOfflineInstallation `
            -ForceOnlineInstallation $using:ForceOnlineInstallation

        Wait-ForSSHConnectionToLinuxVMViaSshKey -Nested:$true
        Copy-KubeConfigFromControlPlaneNode -Nested:$true
    }

    Write-Log 'Windows node initialized.'
}

function Initialize-SSHConnectionToWinVM($session) {
    # remove previous VM key from known hosts
    $sshConfigDir = Get-SshConfigDir
    $file = $sshConfigDir + '\known_hosts'
    if (Test-Path $file) {
        Write-Log 'Remove previous VM key from known_hosts file'
        $ErrorActionPreference = 'Continue'
        ssh-keygen.exe -R $IpAddress 2>&1 | % { "$_" }
        $ErrorActionPreference = 'Stop'
    }

    $windowsVMKey = $sshConfigDir + "\windowsvm\$(Get-SSHKeyFileName)"
    # Create SSH connection with VM
    $sshDir = Split-Path -parent $windowsVMKey

    if (!(Test-Path $sshDir)) {
        mkdir $sshDir | Out-Null
    }

    if (!(Test-Path $windowsVMKey)) {
        Write-Log "Creating SSH key $windowsVMKey ..."

        if ($PSVersionTable.PSVersion.Major -gt 5) {
            echo y | ssh-keygen.exe -t rsa -b 2048 -f $windowsVMKey -N ''
        } else {
            echo y | ssh-keygen.exe -t rsa -b 2048 -f $windowsVMKey -N '""'
        }
    }

    if (!(Test-Path $windowsVMKey)) {
        throw "Unable to generate SSH keys ($windowsVMKey)"
    }

    $rootPublicKey = Get-Content "$windowsVMKey.pub" -Raw

    Invoke-Command -Session $session {
        Set-Location c:\k
        Set-ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue

        $authorizedkeypath = 'C:\ProgramData\ssh\administrators_authorized_keys'

        Write-Output 'Adding public key for SSH connection'

        if ((Test-Path $authorizedkeypath -PathType Leaf)) {
            Write-Output "$authorizedkeypath already exists! overwriting new key"

            Set-Content $authorizedkeypath -Value $using:rootPublicKey
        }
        else {
            New-Item $authorizedkeypath -ItemType File -Value $using:rootPublicKey

            $acl = Get-Acl C:\ProgramData\ssh\administrators_authorized_keys
            $acl.SetAccessRuleProtection($true, $false)
            $administratorsRule = New-Object system.security.accesscontrol.filesystemaccessrule('Administrators', 'FullControl', 'Allow')
            $systemRule = New-Object system.security.accesscontrol.filesystemaccessrule('SYSTEM', 'FullControl', 'Allow')
            $acl.SetAccessRule($administratorsRule)
            $acl.SetAccessRule($systemRule)
            $acl | Set-Acl
        }
    }

    #TODO Check whether copy of local ssh config files necessary
    $targetDirectory = '~\.ssh\kubemaster'
    Write-Log "Creating target directory '$targetDirectory' on VM ..."

    $remoteTargetDirectory = Invoke-Command -Session $session {
        Set-Location "$env:SystemDrive\k"
        Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

        mkdir $using:targetDirectory
    }

    Write-Log "Target directory '$remoteTargetDirectory' created on remote VM."
    $localSourceFiles = "$sshConfigDir\kubemaster\*"
    Copy-Item -ToSession $session $localSourceFiles -Destination "$remoteTargetDirectory" -Recurse -Force
    Write-Log "Copied private key from local '$localSourceFiles' to remote '$remoteTargetDirectory'."
}

function Initialize-PhysicalNetworkAdapterOnVM ($session) {
    Write-Log 'Checking physical network adapter on Windows node ...'

    Invoke-Command -Session $session {
        Set-Location "$env:SystemDrive\k"
        Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

        Import-Module $env:SystemDrive\k\lib\modules\k2s.infra.module\k2s.infra.module.psm1
        Import-Module $env:SystemDrive\k\lib\modules\k2s.node.module\k2s.node.module.psm1
        Initialize-Logging -Nested:$true

        # Install loopback adapter for l2bridge
        New-DefaultLoopbackAdater
    }
}

Export-ModuleMember Get-RootConfigMultivm, Initialize-WinVMNode, Initialize-WinVM