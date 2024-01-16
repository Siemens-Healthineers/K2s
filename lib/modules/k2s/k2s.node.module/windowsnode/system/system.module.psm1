# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

$pathModule = "$PSScriptRoot\..\..\..\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\k2s.infra.module\log\log.module.psm1"
$configModule = "$PSScriptRoot\..\..\..\k2s.infra.module\config\config.module.psm1"
Import-Module $logModule, $pathModule, $configModule

function Addk2sToDefenderExclusion {
    # Stop Microsoft Defender interference with K2s setup
    $kubePath = Get-KubePath
    Add-MpPreference -Exclusionpath "$kubePath" -ErrorAction SilentlyContinue
    Add-MpPreference -ExclusionProcess 'k2s.exe', 'vmmem.exe', 'vmcompute.exe', 'containerd.exe', 'kubelet.exe', 'httpproxy.exe', 'dnsproxy.exe', 'kubeadm.exe', 'kube-proxy.exe', 'bridge.exe', 'containerd-shim-runhcs-v1.exe' -ErrorAction SilentlyContinue
    Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
    Set-MpPreference -DisableBehaviorMonitoring $true -ErrorAction SilentlyContinue
}

function Stop-InstallIfDockerDesktopIsRunning {
    if ((Get-Service 'com.docker.service' -ErrorAction SilentlyContinue).Status -eq 'Running') {
        throw 'Docker Desktop is running! Please stop Docker Desktop in order to continue!'
    }
}

<#
.SYNOPSIS
    Enables a specified Windows feature.
.DESCRIPTION
    Enables a specified Windows feature if disabled.
.PARAMETER Name
    The feature name
.OUTPUTS
    TRUE, if it was necessary to enabled it AND a restart is required. Otherwise, FALSE.
.EXAMPLE
    Enable-MissingFeature -Name 'Containers'
#>
function Enable-MissingFeature {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Name = $(throw 'Please provide the feature name.')
    )

    $featureState = (Get-WindowsOptionalFeature -Online -FeatureName $Name).State

    if ($featureState -match 'Disabled') {
        Write-Log "WindowsOptionalFeature '$Name' is '$featureState'. Will activate feature..."

        $enableResult = Enable-WindowsOptionalFeature -Online -FeatureName $Name -All -NoRestart -WarningAction silentlyContinue

        return $enableResult.RestartNeeded -eq $true
    }

    return $false
}

function Enable-MissingWindowsFeatures($wsl) {
    $restartRequired = $false
    $features = 'Microsoft-Hyper-V-All',
    'Microsoft-Hyper-V',
    'Microsoft-Hyper-V-Tools-All',
    'Microsoft-Hyper-V-Management-PowerShell',
    'Microsoft-Hyper-V-Hypervisor',
    'Microsoft-Hyper-V-Services',
    'Microsoft-Hyper-V-Management-Clients',
    'Containers',
    'VirtualMachinePlatform'

    if ($wsl) {
        $features += 'Microsoft-Windows-Subsystem-Linux'
    }

    foreach ($feature in $features) {
        if (Enable-MissingFeature -Name $feature) {
            $restartRequired = $true
        }
    }

    Write-Log 'Enable windows container version check skip'
    REG ADD 'HKLM\SYSTEM\CurrentControlSet\Control\Windows Containers' /v SkipVersionCheck /t REG_DWORD /d 2 /f

    if ($wsl) {
        Write-Log 'Disable Remote App authentication warning dialog'
        REG ADD 'HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' /V 'AuthenticationLevel' /T REG_DWORD /D '0' /F
    }

    if ($restartRequired) {
        Write-Log '!!! Restart is required. Reason: Changes in WindowsOptionalFeature !!!'
        Restart-Computer -Confirm
        Exit
    }
}

<#
.SYNOPSIS
    Checks the local proxy configuration.
.DESCRIPTION
    Checks the local proxy configuration.
.EXAMPLE
    Test-ProxyConfiguratio
.NOTES
    Throws an error if the configuration is invalid.
    In order to display the correct IP to be configured in the proxy settings, the GlobalVariables.ps1 file must be included in the calling script first.
#>
function Test-ProxyConfiguration() {
    $ipControlPlane = Get-ConfiguredIPControlPlane
    if (($env:HTTP_Proxy).Length -eq 0 -and ($env:HTTPS_Proxy).Length -eq 0 ) {
        return
    }

    if (!$ipControlPlane) {
        throw "The calling script must include the file 'GlobalVariables.ps1' first!"
    }

    if (($env:NO_Proxy).Length -eq 0) {
        Write-Log 'You have configured proxies with environment variable HTTP_Proxy, but the NO_Proxy'
        Write-Log 'is not set. You have to configure NO_Proxy in the system environment variables.'
        Write-Log "NO_Proxy must be set to $ipControlPlane"
        Write-Log "Don't change the variable in the current shell only, that will not work!"
        Write-Log "After configuring the system environment variable, log out and log in!`n"
        throw "NO_Proxy must contain $ipControlPlane"
    }

    if (! ($env:NO_Proxy | Select-String -Pattern "\b$ipControlPlane\b")) {
        Write-Log 'You have configured proxies with environment variable HTTP_Proxy, but the NO_Proxy'
        Write-Log "doesn't contain $ipControlPlane. You have to configure NO_Proxy in the system environment variables."
        Write-Log "Don't change the variable in the current shell only, that will not work!"
        Write-Log "After configuring the system environment variable, log out and log in!`n"
        throw "NO_Proxy must contain $ipControlPlane"
    }
}

function Set-WSL() {
    Write-Log 'Disable Remote App authentication warning dialog'
    REG ADD 'HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' /V 'AuthenticationLevel' /T REG_DWORD /D '0' /F

    wsl --shutdown
    wsl --update
    wsl --version

    $wslConfigPath = "$env:USERPROFILE\.wslconfig"
    if (Test-Path -Path $wslConfigPath) {
        Remove-Item $("$wslConfigPath.old") -Force -ErrorAction SilentlyContinue
        Rename-Item -Path $wslConfigPath -NewName '.wslconfig.old' -Force
    }

    $wslConfig = @"
[wsl2]
swap=0
memory=$MasterVMMemory
processors=$MasterVMProcessorCount
"@
    $wslConfig | Out-File -FilePath $wslConfigPath
}


function Test-WindowsPrerequisites(
    [parameter(Mandatory = $false, HelpMessage = 'Use WSL2 for hosting control plane VM (Linux)')]
    [switch] $WSL = $false) {
    Stop-InstallIfDockerDesktopIsRunning

    $ReleaseId = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild
    if ($ReleaseId -lt 17763) {
        Write-Log "SmallSetup needs minimal Windows Version 1809, you have $ReleaseId"
        throw "Windows release $ReleaseId not usable"
    }

    Enable-MissingWindowsFeatures $([bool]$WSL)

    if ($WSL) {
        Write-Log 'vEthernet (WSL) switch will be reconfigured! Your existing WSL distros will not work properly until you stop the cluster.'
        Write-Log 'Configuring WSL2'
        Set-WSL
    }

    Test-ProxyConfiguration
}

function Get-StorageLocalDrive {
    $storageLocalDriveLetter = ''

    $usedStorageLocalDriveLetter = Get-ConfigUsedStorageLocalDriveLetter
    if (!([string]::IsNullOrWhiteSpace($usedStorageLocalDriveLetter))) {
        $storageLocalDriveLetter = $usedStorageLocalDriveLetter
    }
    else {
        $configuredStorageLocalDriveLetter = Get-ConfiguredStorageLocalDriveLetter
        $searchAvailableFixedLogicalDrives = {
            $fixedHardDrives = Get-WmiObject -ClassName Win32_DiskDrive | Where-Object { $_.Mediatype -eq 'Fixed hard disk media' }
            $partitionsOnFixedHardDrives = $fixedHardDrives | Foreach-Object { Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskDrive.DeviceID=`"$($_.DeviceID.Replace('\','\\'))`"} WHERE AssocClass = Win32_DiskDriveToDiskPartition" }
            $fixedLogicalDrives = $partitionsOnFixedHardDrives | Foreach-Object { Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID=`"$($_.DeviceID)`"} WHERE AssocClass = Win32_LogicalDiskToPartition" }
            return $fixedLogicalDrives | Sort-Object $_.DeviceID
        }
        if ([string]::IsNullOrWhiteSpace($configuredStorageLocalDriveLetter)) {
            $fixedLogicalDrives = $searchAvailableFixedLogicalDrives.Invoke()
            # no drive letter is configured --> use the local drive with the most space available
            $fixedLogicalDriveWithMostSpaceAvailable = $($fixedLogicalDrives | Sort-Object -Property FreeSpace -Descending | Select-Object -Property DeviceID -First 1).DeviceID
            $storageLocalDriveLetter = $fixedLogicalDriveWithMostSpaceAvailable.Substring(0, 1)
        }
        else {
            if ($configuredStorageLocalDriveLetter -match '^[a-zA-Z]$') {
                $storageLocalDriveLetter = $configuredStorageLocalDriveLetter
                $searchedLogicalDeviceID = $storageLocalDriveLetter + ':'
                $fixedLogicalDrives = $searchAvailableFixedLogicalDrives.Invoke()
                $foundFixedLogicalDrive = $fixedLogicalDrives | Where-Object { $_.DeviceID -eq $searchedLogicalDeviceID }
                if ($null -eq $foundFixedLogicalDrive) {
                    $availableFixedLogicalDrives = (($fixedLogicalDrives | Select-Object -Property DeviceID) | ForEach-Object { $_.DeviceID.Substring(0, 1) }) -join ', '
                    throw "The configured local drive letter '$configuredStorageLocalDriveLetter' is not a local fixed drive or is not available in your system.`nYour available local fixed drives are: $availableFixedLogicalDrives. Please choose one of them."
                }
            }
            else {
                throw "The configured local drive letter '$configuredStorageLocalDriveLetter' is syntactically wrong. Please choose just a valid letter of an available local fixed drive."
            }
        }

        Set-ConfigUsedStorageLocalDriveLetter -Value $storageLocalDriveLetter | Out-Null
    }

    if ([string]::IsNullOrWhiteSpace($storageLocalDriveLetter)) {
        throw 'The local drive letter for the storage could not be determined'
    }

    return $storageLocalDriveLetter + ':'
}

<#
.Description
Invoke-DownloadFile download file from internet.
#>
function Invoke-DownloadFile($destination, $source, $forceDownload,
    [parameter(Mandatory = $false)]
    [string] $ProxyToUse = $Proxy) {
    if ((Test-Path $destination) -and (!$forceDownload)) {
        Write-Log "using existing $destination"
        return
    }
    if ( $ProxyToUse -ne '' ) {
        Write-Log "Downloading '$source' to '$destination' with proxy: $ProxyToUse"
        curl.exe --retry 5 --retry-connrefused --retry-delay 60 --silent --disable --fail -Lo $destination $source --proxy $ProxyToUse --ssl-no-revoke -k #ignore server certificate error for cloudbase.it
    }
    else {
        Write-Log "Downloading '$source' to '$destination' (no proxy)"
        curl.exe --retry 5 --retry-connrefused --retry-delay 60 --silent --disable --fail -Lo $destination $source --ssl-no-revoke --noproxy '*'
    }

    if (!$?) {
        if ($ErrorActionPreference -eq 'Stop') {
            #If Stop is the ErrorActionPreference from the caller then Write-Error throws an exception which is not logged in k2s.log file.
            #So we need to write a warning to capture Download failed information in the log file.
            Write-Warning "Download '$source' failed"
        }
        Write-Error "Download '$source' failed"
        exit 1
    }
}

Export-ModuleMember -Function Addk2sToDefenderExclusion,
Stop-InstallIfDockerDesktopIsRunning,
Test-WindowsPrerequisites,
Test-ProxyConfiguration,
Get-StorageLocalDrive,
Invoke-DownloadFile