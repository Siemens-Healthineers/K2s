# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

$pathModule = "$PSScriptRoot\..\..\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\k2s.infra.module\log\log.module.psm1"
$vmnodeModule = "$PSScriptRoot\..\..\k2s.node.module\vmnode\vmnode.module.psm1"
Import-Module $pathModule, $logModule, $vmnodeModule

$rootConfig = Get-RootConfig

$multivmRootConfig = $rootConfig.psobject.properties['multivm'].value

function Get-RootConfigMultivm {
    return $multivmRootConfig
}

function Initialize-WinVmNode {
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

    $giturlk = "https://github.com/Siemens-Healthineers/K2s.git"
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

    # Password for Linux/Windows VMs during installation
    $vmPwd = 'admin'

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

}

Export-ModuleMember Get-RootConfigMultivm, Initialize-WinVmNode