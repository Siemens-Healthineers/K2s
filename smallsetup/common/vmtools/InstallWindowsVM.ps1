# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Assists with creating a windows VM

.DESCRIPTION
This script assists in the following actions for K2s:
- Downloads windows image and creates VM

.EXAMPLE
powershell <installation folder>\common\vmtools\InstallWindowsVM.ps1 -Name Windows2004 -Image d:\windows2004.iso
powershell <installation folder>\common\vmtools\InstallWindowsVM.ps1 -Name Windows21H1 -OsVersion 21H1
powershell <installation folder>\common\vmtools\InstallWindowsVM.ps1 -Name Windows21H1 -OsVersion 21H1 -Proxy http://your-proxy.example.com:8888
#>

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
    [string]$Locale = 'en-US',
    [parameter(Mandatory = $false, HelpMessage = 'Based on flag complete download of artifacts needed for k2s install are download')]
    [switch] $DownloadNodeArtifacts = $false
)

$ErrorActionPreference = 'Continue'
if ($Trace) {
    Set-PSDebug -Trace 1
}

# load global settings
&$PSScriptRoot\..\GlobalVariables.ps1

# import global functions
&$PSScriptRoot\..\GlobalFunctions.ps1

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
else {
    if (!(Test-Path $Image)) {
        Write-Log 'Image file not found !'
        throw 'Image check'
    }
}

# set default values for switch
if ($SwitchName -eq '') {
    $SwitchName = 'k2sSetup'
}
if ($SwitchIP -eq '') {
    $SwitchIP = '172.29.29.1'
}

$giturlk = "https://github.com/Siemens-Healthineers/K2s.git"
Write-Log "Git url for k: $giturlk"

# check prerequisites
$virtualizedNetworkCIDR = '172.29.29.0/24'
$virtualizedNAT = 'k2sSetup'

Write-Log 'Checking windows iso image location'

if (! (Test-Path $Image)) {
    throw "Missing VM image: $Image"
}

if ($CreateSwitch -eq $true) {
    # try to create switch
    $swtype = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty SwitchType
    if ( $swtype -eq 'Private') {
        Write-Log "Switch: $SwitchName is corrupted, try to delete it"
        throw "Hyper-V switch $SwitchName is corrupted, please delete it in Hyper-V Manager (before disconnect all VMs from it), do a UninstallVM and start from scratch !"
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
    $virtioImgFile = &"$global:KubernetesPath\smallsetup\common\vmtools\Get-VirtioImage.ps1" -Verbose -Proxy "$Proxy"
    Write-Log "Virtio image: $virtioImgFile"
}

# check edition
if ($Edition -eq '') {
    $Edition = 'Windows 10 Pro'
}

# install vm where we would run the K2s setup
Write-Log "Create VM $Name"
Write-Log "Using $VMStartUpMemory of memory for VM"
Write-Log "Using $VMDiskSize of virtual disk space for VM"
Write-Log "Using $VMProcessorCount of virtual processor count for VM"
Write-Log "Using image: $Image"
Write-Log "Using virtio image: $virtioImgFile"
Write-Log "Using generation: $Generation"
Write-Log "Using edition: $Edition"
Write-Log "Using locale: $Locale"
&"$global:KubernetesPath\smallsetup\common\vmtools\New-VMFromWinImage.ps1" `
    -ImgDir $Image `
    -WinEdition $Edition `
    -Name $Name `
    -AdminPwd $global:VMPwd `
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
$session1 = Open-RemoteSession -VmName $Name -VmPwd $global:VMPwd
Write-Log "Set ip address: $IpAddress"
&"$global:KubernetesPath\smallsetup\common\vmtools\Set-NetIPAddr.ps1" -PSSession $session1 -IPAddr $IpAddress -DefaultGatewayIpAddr $SwitchIP -DnsAddr $DnsAddresses -MaskPrefixLength 24

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

$session2 = Open-RemoteSession -VmName $Name -VmPwd $global:VMPwd

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

Write-Log 'Download k2s source from git'
Invoke-Command -Session $session2 -ErrorAction SilentlyContinue {
    New-Item -ItemType Directory -Force c:\k
    Set-Location c:\k
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

$kubernetesVersion = $global:KubernetesVersion

$session3 = Open-RemoteSession -VmName $Name -VmPwd $global:VMPwd

Invoke-Command -Session $session3 {
    Set-Location c:\k
    Set-ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue
    # load global settings
    &$env:SystemDrive\k\smallsetup\common\GlobalVariables.ps1
    Import-Module $env:SystemDrive\k\smallsetup\ps-modules\log\log.module.psm1
    Initialize-Logging -Nested:$true

    Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.node.module\windowsnode\system\system.module.psm1
    Stop-InstallationIfRequiredCurlVersionNotInstalled

    New-Item -ItemType Directory "$global:KubernetesPath\lib\NSSM"
    Copy-Item -Path 'C:\ProgramData\chocolatey\lib\NSSM\*' -Destination "$global:KubernetesPath\lib\NSSM" -Recurse -Force
    Copy-Item -Path 'C:\ProgramData\chocolatey\bin\nssm.exe' -Destination "$global:KubernetesPath\bin" -Force

    if ($using:DownloadNodeArtifacts) {
        Write-Output 'DownloadNodeArtifacts is set, downloading all windows node artifacts ..'
        &"$global:KubernetesPath\smallsetup\windowsnode\DeployWindowsNodeArtifacts.ps1" -KubernetesVersion $using:kubernetesVersion -Proxy $using:Proxy -ForceOnlineInstallation $true -SetupType $global:SetupType_MultiVMK8s
    }
    else {
        Write-Output 'DownloadNodeArtifacts is not set, downloading docker  ..'
        &"$global:KubernetesPath\smallsetup\windowsnode\downloader\DownloadDocker.ps1" -Proxy $using:Proxy -Deploy
    }

    &"$global:KubernetesPath\smallsetup\windowsnode\publisher\PublishDocker.ps1"

    if (!$using:DownloadNodeArtifacts) {
        Write-Output "DownloadNodeArtifacts is not set, removing intermediate download folders '$global:KubernetesPath\bin\downloads', '$global:KubernetesPath\bin\windowsnode'"
        Remove-Item -Path "$global:KubernetesPath\bin\downloads" -Force -Recurse -ErrorAction SilentlyContinue
        Remove-Item -Path "$global:KubernetesPath\bin\windowsnode" -Force -Recurse -ErrorAction SilentlyContinue
    }

    if ($using:Proxy) {
        Write-Output "Installing Docker Engine using Proxy $using:Proxy .."
        &"$global:KubernetesPath\smallsetup\windowsnode\InstallDockerWin10.ps1" -Proxy $using:Proxy
    }
    else {
        Write-Output 'Installing Docker Engine with no proxy ..'
        &"$global:KubernetesPath\smallsetup\windowsnode\InstallDockerWin10.ps1"
    }
}

$session4 = Open-RemoteSession -VmName $Name -VmPwd $global:VMPwd

$pr = ''
if ( $Proxy ) { $pr = $Proxy.Replace('http://', '') }
$NoProxy = "localhost,$global:IP_Master,$global:ClusterCIDR,$global:ClusterCIDR_Services,svc.cluster.local"
Invoke-Command -Session $session4 {
    Set-Location c:\k
    Set-ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue
    # load global settings
    &$env:SystemDrive\k\smallsetup\common\GlobalVariables.ps1
    . $env:SystemDrive\k\smallsetup\common\GlobalFunctions.ps1
    Import-Module $env:SystemDrive\k\smallsetup\ps-modules\log\log.module.psm1
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
    Add-MpPreference -Exclusionpath 'C:\k'
    Add-MpPreference -ExclusionProcess 'k2s.exe', 'vmmem.exe', 'vmcompute.exe', 'containerd.exe', 'kubelet.exe', 'httpproxy.exe', 'dnsproxy.exe', 'kubeadm.exe', 'kube-proxy.exe', 'containerd-shim-runhcs-v1.exe'
    Set-MpPreference -DisableRealtimeMonitoring $true
    Set-MpPreference -DisableBehaviorMonitoring $true

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

$session5 = Open-RemoteSession -VmName $Name -VmPwd $global:VMPwd

Invoke-Command -Session $session5 -WarningAction SilentlyContinue {
    Set-ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue
    Import-Module $env:SystemDrive\k\smallsetup\ps-modules\log\log.module.psm1
    Write-Output 'Adjusting after reboot'

    Set-Service -Name sshd -StartupType Automatic
    Start-Service sshd
    nssm status sshd

    Set-Service -Name docker -StartupType Automatic
    Start-Service docker
    nssm status docker

    Write-Output 'Enable windows container version check skip'
    REG ADD 'HKLM\SYSTEM\CurrentControlSet\Control\Windows Containers' /v SkipVersionCheck /t REG_DWORD /d 2 /f
}

# all done
Write-Log "All steps done, VM $Name now available !"