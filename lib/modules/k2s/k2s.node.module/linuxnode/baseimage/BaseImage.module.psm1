# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

$validationModule = "$PSScriptRoot\..\..\..\k2s.infra.module\validation\validation.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\k2s.infra.module\log\log.module.psm1"
$vmModule = "$PSScriptRoot\..\vm\vm.module.psm1"

Import-Module $validationModule, $logModule, $vmModule

# Base image

<#
.Description
#TODO Move to infra module if used frequently in linux node
Invoke-DownloadFile download file from internet.
#>
function Invoke-Download($destination, $source, $forceDownload,
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

<#
.Description
#From Get-DebianImage.ps1
#>
function Invoke-DownloadDebianImage {
    param(
        [string]$OutputPath,
        [string]$Proxy = ''
    )

    $urlRoot = 'https://cloud.debian.org/images/cloud/bullseye/latest'

    $urlFile = 'debian-11-genericcloud-amd64.qcow2'

    $url = "$urlRoot/$urlFile"

    if (-not $OutputPath) {
        $OutputPath = Get-Item '.\'
    }

    $imgFile = Join-Path $OutputPath $urlFile

    if ([System.IO.File]::Exists($imgFile)) {
        # use Write-Host to not add the entries to the returned stream !
        # don't use here write-output, because that adds the output to returned value
        Write-Log "File '$imgFile' already exists. Nothing to do."
    }
    else {
        Invoke-Download $imgFile $url $false $Proxy

        Write-Log 'Checking file integrity...'
        $allHashs = ''

        if ( $Proxy -ne '') {
            Write-Log "Using Proxy $Proxy to download SHA sum from $urlRoot"
            $allHashs = curl.exe --retry 3 --retry-connrefused --silent --disable --fail "$urlRoot/SHA512SUMS" --proxy $Proxy --ssl-no-revoke -k
        }
        else {
            $allHashs = curl.exe --retry 3 --retry-connrefused --silent --disable --fail "$urlRoot/SHA512SUMS" --ssl-no-revoke --noproxy '*'
        }

        $sha1Hash = Get-FileHash $imgFile -Algorithm SHA512
        $m = [regex]::Matches($allHashs, "(?<Hash>\w{128})\s\s$urlFile")
        if (-not $m[0]) { throw "Cannot get hash for $urlFile." }
        $expectedHash = $m[0].Groups['Hash'].Value
        if ($sha1Hash.Hash -ne $expectedHash) { throw "Integrity check for '$imgFile' failed." }
        Write-Log '  ...done'
    }

    return $imgFile
}


Function New-VhdxDebianCloud {
    param (
        [Parameter(Mandatory = $false)]
        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [string]$TargetFilePath,
        [Parameter(Mandatory = $false, ValueFromPipeline=$true)]
        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [string]$DownloadsDirectory,
        [parameter(Mandatory = $false)]
        [string]$Proxy = ''
    )

    Assert-Path -Path $TargetFilePath -PathType "Leaf" -ShallExist $false | Out-Null
    $pathContainer = $(Split-Path $TargetFilePath)
    Assert-Path -Path $pathContainer -PathType "Container" -ShallExist $true | Out-Null

    Assert-Path -Path $DownloadsDirectory -PathType "Container" -ShallExist $true | Out-Null

    $debianImage = Get-DebianImage -Proxy $Proxy -DownloadsDirectory $DownloadsDirectory | Assert-Path -PathType "Leaf" -ShallExist $true
    $qemuTool = Get-QemuTool -Proxy $Proxy -DownloadsDirectory $DownloadsDirectory | Assert-Path -PathType "Leaf" -ShallExist $true
    $vhdxFile = New-VhdxFile -SourcePath $debianImage -VhdxPath $TargetFilePath -QemuExePath $qemuTool | Assert-Path -PathType "Leaf" -ShallExist $true
}


Function Get-DebianImage {
    param (
        [Parameter(Mandatory = $false, ValueFromPipeline=$true)]
        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [string]$DownloadsDirectory,
        [parameter(Mandatory = $false, HelpMessage = 'The HTTP proxy if available.')]
        [string]$Proxy = ''
    )
    Assert-Path -Path $DownloadsDirectory -PathType 'Container' -ShallExist $true | Out-Null

    $imgFile = Invoke-DownloadDebianImage $DownloadsDirectory $Proxy

    Write-Output $imgFile
}

Function Get-QemuTool {
    param (
        [Parameter(Mandatory = $false, ValueFromPipeline=$true)]
        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [string]$DownloadsDirectory,
        [parameter(Mandatory = $false, HelpMessage = 'The HTTP proxy if available.')]
        [string]$Proxy = ''
    )
    Assert-Path -Path $DownloadsDirectory -PathType "Container" -ShallExist $true | Out-Null

    $qemuTool = Get-QemuExecutable -Proxy $Proxy -OutputDirectory $DownloadsDirectory

    Write-Output $qemuTool
}

Function New-VhdxFile {
    param (
        [Parameter(Mandatory = $false)]
        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [string]$SourcePath,
        [Parameter(Mandatory = $false)]
        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [string]$VhdxPath,
        [Parameter(Mandatory = $false)]
        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [string]$QemuExePath
    )
    Assert-Path -Path $SourcePath -PathType "Leaf" -ShallExist $true | Out-Null
    Assert-Path -Path $VhdxPath -PathType "Leaf" -ShallExist $false | Out-Null
    $pathContainer = $(Split-Path $VhdxPath)
    Assert-Path -Path $pathContainer -PathType "Container" -ShallExist $true | Out-Null
    Assert-Path -Path $QemuExePath -PathType "Leaf" -ShallExist $true | Out-Null

    Invoke-Tool -ToolPath $QemuExePath -Arguments "convert -f qcow2 `"$SourcePath`" -O vhdx -o subformat=dynamic `"$VhdxPath`""
    Assert-Path -Path $VhdxPath -PathType "Leaf" -ShallExist $true | Out-Null

    $VhdxPath
}

Function New-IsoFile {
    param (
        [Parameter(Mandatory = $false)]
        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [string]$IsoFileCreatorToolPath = $(throw 'Parameter missing: IsoFileCreatorToolPath'),

        [Parameter(Mandatory = $false)]
        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [ValidateScript({ Assert-Pattern -Path $_ -Pattern "^.*\.iso$" })]
        [string]$IsoFilePath = $(throw 'Parameter missing: IsoFilePath'),

        [Parameter(Mandatory = $false)]
        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [string]$SourcePath = $(throw 'Parameter missing: SourcePath'),

        [Parameter(Mandatory = $false)]
        #[ValidateScript({ Assert-IsoContentParameters -Value $_ })]
        [hashtable]$IsoContentParameterValue = $(throw 'Parameter missing: IsoContentParameterValue')
    )
    Assert-Path -Path $IsoFileCreatorToolPath -PathType "Leaf" -ShallExist $true | Out-Null
    Assert-Path -Path $IsoFilePath -PathType "Leaf" -ShallExist $false | Out-Null
    $private:workingDirectory = $(Split-Path $IsoFilePath)
    Assert-Path -Path $workingDirectory -PathType "Container" -ShallExist $true | Out-Null

    Assert-Path -Path $SourcePath -PathType "Container" -ShallExist $true | Out-Null

    $private:cloudDataTargetDirectory = "$workingDirectory\cloud-data"
    Assert-Path -Path $cloudDataTargetDirectory -PathType "Container" -ShallExist $false | Out-Null
    New-Item -Path $cloudDataTargetDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null

    $metaDataTemplateFilePath = "$SourcePath\meta-data"
    $networkConfigTemplateFilePath = "$SourcePath\network-config"
    $userDataTemplateFilePath = "$SourcePath\user-data"
    Assert-Path -Path $metaDataTemplateFilePath -PathType "Leaf" -ShallExist $true | Out-Null
    Assert-Path -Path $networkConfigTemplateFilePath -PathType "Leaf" -ShallExist $true | Out-Null
    Assert-Path -Path $userDataTemplateFilePath -PathType "Leaf" -ShallExist $true | Out-Null

    $metaDataFileContent = Get-Content -Path $metaDataTemplateFilePath -Raw -ErrorAction Stop
    $metaDataConversionTable = @{
        "__INSTANCE_NAME__"=(New-Guid).Guid
        "__LOCAL-HOSTNAME_VALUE__"=$IsoContentParameterValue.Hostname
    }
    Convert-Text -Source $metaDataFileContent -ConversionTable $metaDataConversionTable | Set-Content -Path "$cloudDataTargetDirectory\meta-data" -ErrorAction Stop

    $networkConfigFileContent = Get-Content -Path $networkConfigTemplateFilePath -Raw -ErrorAction Stop
    $networkConfigConversionTable = @{
        "__NETWORK_INTERFACE_NAME__"=$IsoContentParameterValue.NetworkInterfaceName
        "__IP_ADDRESS_VM__"=$IsoContentParameterValue.IPAddressVM
        "__IP_ADDRESS_GATEWAY__"=$IsoContentParameterValue.IPAddressGateway
        "__IP_ADDRESSES_DNS_SERVERS__"=$IsoContentParameterValue.IPAddressDnsServers
    }
    Convert-Text -Source $networkConfigFileContent -ConversionTable $networkConfigConversionTable | Set-Content -Path "$cloudDataTargetDirectory\network-config" -ErrorAction Stop

    $userDataFileContent = Get-Content -Path $userDataTemplateFilePath -Raw -ErrorAction Stop
    $userDataConversionTable = @{
        "__LOCAL-HOSTNAME_VALUE__"=$IsoContentParameterValue.Hostname
        "__VM_USER__"=$IsoContentParameterValue.UserName
        "__VM_USER_PWD__"=$IsoContentParameterValue.UserPwd
        "__IP_ADDRESSES_DNS_SERVERS__"=($IsoContentParameterValue.IPAddressDnsServers -replace ",", "\n nameserver ")
    }
    Convert-Text -Source $userDataFileContent -ConversionTable $userDataConversionTable | Set-Content -Path "$cloudDataTargetDirectory\user-data" -ErrorAction Stop

    Invoke-Tool -ToolPath $IsoFileCreatorToolPath -Arguments "-sourceDir `"$cloudDataTargetDirectory`" -targetFilePath `"$IsoFilePath`""

    Assert-Path -Path $IsoFilePath -PathType "Leaf" -ShallExist $true | Out-Null

    $IsoFilePath
}

<#
.SYNOPSIS
Creates a root filesystem to be used with WSL
.DESCRIPTION
A vhdx file is copied from the Windows host to the running VM
and a filesystem file is created inside the running VM out of the vhdx file's content.
The filesystem file is then compressed an sent to the Windows host.
.PARAMETER IpAddress
The IP address of the VM.
.PARAMETER UserName
The user name to log in into the VM.
.PARAMETER UserPwd
The password to use to log in into the VM.
.PARAMETER VhdxFile
The full path of the vhdx file that will be used to create the filesystem.
.PARAMETER RootfsName
The full path for the output filesystem file.
.PARAMETER TargetPath
The path to a directory where the filesystem file will saved after compression and before being sent to the Windows host
#>
Function New-RootfsForWSL {
    param (
        [string] $IpAddress = $(throw "Argument missing: IpAddress"),
        [string] $UserName = $(throw "Argument missing: UserName"),
        [string] $UserPwd = $(throw "Argument missing: UserPwd"),
        [string] $VhdxFile = $(throw "Argument missing: VhdxFile"),
        [string] $RootfsName = $(throw "Argument missing: RootfsName"),
        [string] $TargetPath = $(throw "Argument missing: TargetPath")
    )
    $user = "$UserName@$IpAddress"
    $userPwd = $UserPwd

    $executeRemoteCommand = {
        param(
            $command = $(throw "Argument missing: Command"),
            [switch]$IgnoreErrors = $false
            )
        if ($IgnoreErrors) {
            Invoke-CmdOnControlPlaneViaUserAndPwd $command -RemoteUser "$user" -RemoteUserPwd "$userPwd" -IgnoreErrors
        } else {
            Invoke-CmdOnControlPlaneViaUserAndPwd $command -RemoteUser "$user" -RemoteUserPwd "$userPwd"
        }
    }

    Write-Log "Creating $RootfsName for WSL2"

    $targetFile = "$TargetPath\$RootfsName"
    Write-Log "Remove file '$targetFile' if existing"
    if (Test-Path $targetFile) {
        Remove-Item $targetFile -Force
    }

    &$executeRemoteCommand "sudo mkdir -p /tmp/rootfs"
    &$executeRemoteCommand "sudo chmod 755 /tmp/rootfs"
    &$executeRemoteCommand "sudo chown $UserName /tmp/rootfs"

    $target = '/tmp/rootfs/'
    $filename = Split-Path $VhdxFile -Leaf
    Copy-ToControlPlaneViaUserAndPwd -Source $VhdxFile -Target $target

    &$executeRemoteCommand "cd /tmp/rootfs && sudo mkdir mntfs"
    &$executeRemoteCommand "cd /tmp/rootfs && sudo modprobe nbd"
    &$executeRemoteCommand "cd /tmp/rootfs && sudo qemu-nbd -c /dev/nbd0 ./$filename"

    $waitFile = @'
#!/bin/bash \n

waitFile() { \n
    local START=$(cut -d '.' -f 1 /proc/uptime) \n
    local MODE=${2:-"a"} \n
    until [[ "${MODE}" = "a" && -e "$1" ]] || [[ "${MODE}" = "d" && ( ! -e "$1" ) ]]; do \n
        sleep 1s \n
        if [ -n "$3" ]; then \n
        local NOW=$(cut -d '.' -f 1 /proc/uptime) \n
        local ELAPSED=$(( NOW - START )) \n
        if [ $ELAPSED -ge "$3" ]; then break; fi \n
        fi \n
    done \n
} \n

$@ \n
'@

    &$executeRemoteCommand "sudo touch /tmp/rootfs/waitfile.sh"
    &$executeRemoteCommand "sudo chmod +x /tmp/rootfs/waitfile.sh"
    &$executeRemoteCommand "echo -e '$waitFile' | sudo tee -a /tmp/rootfs/waitfile.sh" | Out-Null
    &$executeRemoteCommand "cd /tmp/rootfs && sed -i 's/\r//g' waitfile.sh"
    &$executeRemoteCommand "cd /tmp/rootfs && ./waitfile.sh waitFile /dev/nbd0p1 'a' 30"

    &$executeRemoteCommand "cd /tmp/rootfs && sudo mount /dev/nbd0p1 mntfs"

    &$executeRemoteCommand "cd /tmp/rootfs && sudo cp -a mntfs rootfs"

    &$executeRemoteCommand "cd /tmp/rootfs && sudo umount mntfs"
    &$executeRemoteCommand "cd /tmp/rootfs && sudo qemu-nbd -d /dev/nbd0"
    &$executeRemoteCommand "cd /tmp/rootfs && ./waitfile.sh waitFile /dev/nbd0p1 'd' 30"
    &$executeRemoteCommand "cd /tmp/rootfs && sudo rmmod nbd"
    &$executeRemoteCommand "cd /tmp/rootfs && sudo rmdir mntfs"

    &$executeRemoteCommand "cd /tmp/rootfs && sudo rm $filename"

    &$executeRemoteCommand "cd /tmp/rootfs && sudo tar -zcpf rootfs.tar.gz -C ./rootfs ."  -IgnoreErrors
    &$executeRemoteCommand 'cd /tmp/rootfs && sudo chown "$(id -un)" rootfs.tar.gz'

    Copy-FromControlPlaneViaUserAndPwd -Source "/tmp/rootfs/rootfs.tar.gz" -Target "$TargetPath"
    Rename-Item -Path "$TargetPath\rootfs.tar.gz" -NewName $RootfsName -Force -ErrorAction SilentlyContinue
    Remove-Item "$TargetPath\rootfs.tar.gz" -Force -ErrorAction SilentlyContinue
    &$executeRemoteCommand "sudo rm -rf /tmp/rootfs"

    $kubemasterRootfsPath = Get-ControlPlaneVMRootfsPath
    if (!(Test-Path $kubemasterRootfsPath)) {
        throw "The provisioned base image is not available as $kubemasterRootfsPath for WSL2"
    }
    Write-Log "Provisioned base image available as $kubemasterRootfsPath for WSL2"
}

<#
.SYNOPSIS
Finds the DNS IP address of the Windows host
.DESCRIPTION
Returns a comma separated list of DNS IP addresses that are configured in the active physical card of the Windows host.
#>
Function Find-DnsIpAddress {
    $ipaddressesFromDhcp = @(Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Dhcp -AddressState Preferred -ErrorAction SilentlyContinue)
    if (!$ipaddressesFromDhcp) {
    	Write-Log "No DHCP entry found, try to get the Ethernet NIC"
    	$ipaddressesFromDhcp = @(Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred -InterfaceAlias Ethernet -ErrorAction SilentlyContinue)
    }
    if (!$ipaddressesFromDhcp) {
    	throw 'No IP address found which can be used for setting up Small K8s Setup !'
    }
    if ($ipaddressesFromDhcp.Length -gt 1) {
    	Write-Warning "Found more than one IP address, using the first one only"
    }
    $ipaddress = $ipaddressesFromDhcp[0] | Select-Object -ExpandProperty IPAddress
    Write-Log "Windows host IP address: $ipaddress"
    $interfaceIndex = $ipaddressesFromDhcp[0] | Select-Object -ExpandProperty InterfaceIndex
    $dnsEntries = (Get-DnsClientServerAddress -InterfaceIndex $interfaceIndex | Select-Object -ExpandProperty ServerAddresses) -join ","
    Write-Log "Windows host DNS IP addresses: $dnsEntries"

    return $dnsEntries
}

Function Get-QemuExecutable {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $false, HelpMessage = 'The HTTP proxy if available.')]
        [string]$Proxy = '',
        [parameter(Mandatory = $true, HelpMessage = 'The directory where the executable will be available.')]
        [string]$OutputDirectory
    )

    # download and make qemu-img.exe available
    $zipFileName = 'qemu-img-win-x64-2_3_0.zip'
    $zipFilePath = Join-Path $OutputDirectory "$zipFileName"
    $url = "https://cloudbase.it/downloads/$zipFileName"
    if (!(Test-Path $zipFilePath)) {
        Write-Log "Start download..."
        Invoke-Download $zipFilePath $url $true $Proxy
        Write-Log "  ...done"
    }
    else {
        Write-Log "Using existing '$zipFilePath'"
    }

    # Extract the archive.
    Write-Log "Extract archive to '$OutputDirectory'"
    Expand-Archive $zipFilePath -DestinationPath $OutputDirectory -Force

    $qemuExePath = Join-Path $OutputDirectory "qemu-img.exe"
    Write-Log "Qemu-img downloaded and available as '$qemuExePath'"

    return $qemuExePath
}

## Virtual Machine

Function New-VirtualMachineForBaseImageProvisioning {
	param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string] $VmName,

        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [ValidateScript({ Assert-Pattern -Path $_ -Pattern "^.*\.vhdx$" })]
        [string] $VhdxFilePath,

        [string] $IsoFilePath = $(throw "Argument missing: IsoFilePath"),

        [ValidateScript( { $_ -gt 0 })]
        [long]$VMMemoryStartupBytes,

        [ValidateScript( { $_ -gt 0 })]
        [long]$VMProcessorCount,

        [ValidateScript( { $_ -gt 0 })]
        [uint64]$VMDiskSize
        )

        $useIsoFilePath = (!([string]::IsNullOrWhiteSpace($IsoFilePath)))
        if ($useIsoFilePath) {
            $hasLegalCharactersInPath = Assert-LegalCharactersInPath -Path $IsoFilePath
            if (!$hasLegalCharactersInPath) {
                throw "The file $IsoFilePath contains illegal characters"
            }
            $validIsoPath = Assert-Pattern -Path $IsoFilePath -Pattern "^.*\.iso$"
            if (!$validIsoPath) {
                throw "The file $IsoFilePath does not match the pattern '*.iso'"
            }
            Assert-Path -Path $IsoFilePath -PathType "Leaf" -ShallExist $true | Out-Null
        }

        Assert-Path -Path $VhdxFilePath -PathType "Leaf" -ShallExist $true | Out-Null

	    Write-Log "Create new VM named $VmName"
	    New-VM -Name $VmName -vhdPath $VhdxFilePath -ErrorAction Stop | Write-Log
	    Write-Log "  - set its memory to $VMMemoryStartupBytes"
	    Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $false -StartupBytes $VMMemoryStartupBytes -ErrorAction Stop
	    Write-Log "  - set its cpu count to $VMProcessorCount"
	    Set-VMProcessor -VMName $VmName -Count $VMProcessorCount -ErrorAction Stop
	    if ($useIsoFilePath) {
	    	Write-Log "  - set its DVD drive with $IsoFilePath"
	    	Set-VMDvdDrive -VMName $VmName -Path $IsoFilePath -ErrorAction Stop
	    }
	    Write-Log "  - resize it to $VMDiskSize"
	    Resize-VHD -Path $VhdxFilePath -SizeBytes $VMDiskSize -ErrorAction Stop
}

<#
.SYNOPSIS
Removes the VM used for provisioning
.DESCRIPTION
If the VM is found by using its name it is first disconnected from the Switch and afterwards deleted.
The given vhdx file is also deleted if existing.
.PARAMETER VmName
The name of the VM.
.PARAMETER VhdxFilePath
The full path to the vhdx file that was used with the VM.
#>
Function Remove-VirtualMachineForBaseImageProvisioning {
	param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string] $VmName = $(throw "Argument missing: VmName"),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string] $VhdxFilePath = $(throw "Argument missing: VhdxFilePath")
    )

    Disconnect-VmFromSwitch -VmName $VmName

    Write-Log "Removing the VM $VmName"
    $vm = Get-VM | Where-Object Name -Like $VmName
    if ($vm -ne $null) {
        Remove-VM -Name $VmName -Force
    }

    if (Test-Path $VhdxFilePath) {
        Remove-Item -Path $VhdxFilePath -Force
    }
}

function Connect-VmToSwitch {
	param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string] $VmName = $(throw "Argument missing: VmName"),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string] $SwitchName = $(throw "Argument missing: SwitchName")
        )

	Write-Log "Connect VM '$VmName' to the switch $SwitchName"
	Connect-VMNetworkAdapter -VmName $VmName -SwitchName $SwitchName -ErrorAction Stop
}

function Disconnect-VmFromSwitch {
	param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string] $VmName = $(throw "Argument missing: VmName")
        )

	Write-Log "Disconnect VM '$VmName' from switch"
    $vmFound = Get-VM | Where-Object Name -eq $VmName | Select-Object -ExpandProperty VmName
    if ($null -ne $vmFound) {
	    Disconnect-VMNetworkAdapter -VmName $VmName -ErrorAction Stop
    }
}

<#
.SYNOPSIS
Starts a VM using its name.
.DESCRIPTION
The VM with the given name is started and awaited until it sends two heartbeats.
.PARAMETER Name
The name of the VM.
#>
function Start-VirtualMachineAndWaitForHeartbeat {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string] $Name = $(throw "Argument missing: Name")
        )
    Start-VM -Name $Name
    Write-Log "Waiting for VM to send heartbeat..."
    Wait-VM -Name $Name -For Heartbeat
    Write-Log "   heartbeat received. Waiting for VM to send heartbeat again..."
    Wait-VM -Name $Name -For Heartbeat
    Write-Log "  ok"

    Write-Log "VM '$Name' started"
}

<#
.SYNOPSIS
Creates a VM that has the OS debian cloud.
.DESCRIPTION
It creates a VM that uses a vhdx file having the OS debian cloud and attaches it to an iso file for cloud init on first start.
.PARAMETER VirtualMachineParams
A hashtable containing the parameters used for the VM. The needed keys are:
- VmName: the name of the VM
- VhdxName: the vhdx file name
- VMMemoryStartupBytes: the amount of startup bytes
- VMProcessorCount: the amount of CPU cores
- VMDiskSize: the size of the disk

.PARAMETER NetworkParams
A hashtable containing the parameters used for networking. The needed keys are:
- Proxy: the HTTP proxy to use
- SwitchName: the name of the switch to connect the VM
- HostIpAddress: the IP address of the Windows host
- HostIpPrefixLength: the prefix length of the host IP
- NatName: the name of the NAT
- NatIpAddress: the IP address of the NAT

.PARAMETER IsoFileParams
A hashtable containing the parameters used for creating the iso file. The needed keys are:
- IsoFileCreatorToolPath: the full path to the tool used for iso file creation
- IsoFileName: the name of the iso file
- SourcePath: the path to the sources that will be part of the iso file
- Hostname: the hostname that will have the VM
- NetworkInterfaceName: the name of the network adapter inside the VM
- IPAddressVM: the IP address of the VM
- IPAddressGateway: the gateway IP address that the VM will use
- UserName: the user name to log in into the VM
- UserPwd: the user password to log in into the VM

.PARAMETER WorkingDirectoriesParams
A hashtable containing the directories that will be used. The needed keys are:
- DownloadsDirectory: the full path of the directory where the artifacts downloaded from the internet will be stored.
- ProvisioningDirectory: the full path of the directory where the artifacts used during provisioning will be stored.
#>
Function New-DebianCloudBasedVirtualMachine {
    Param (
        [Hashtable]$VirtualMachineParams,
        [Hashtable]$NetworkParams,
        [Hashtable]$IsoFileParams,
        [Hashtable]$WorkingDirectoriesParams
    )
    $vmName = $VirtualMachineParams.VmName
    $inProvisioningVhdxName = $VirtualMachineParams.VhdxName
    $VMMemoryStartupBytes=$VirtualMachineParams.VMMemoryStartupBytes
    $VMProcessorCount=$VirtualMachineParams.VMProcessorCount
    $VMDiskSize=$VirtualMachineParams.VMDiskSize

    $Proxy = $NetworkParams.Proxy
    $SwitchName=$NetworkParams.SwitchName
    $HostIpAddress=$NetworkParams.HostIpAddress
    $HostIpPrefixLength=$NetworkParams.HostIpPrefixLength
    $NatName=$NetworkParams.NatName
    $NatIpAddress=$NetworkParams.NatIpAddress

    $IsoFileCreatorToolPath = $IsoFileParams.IsoFileCreatorToolPath
    $IsoFileName = $IsoFileParams.IsoFileName
    $IsoContentTemplateSourcePath = $IsoFileParams.SourcePath
    $Hostname=$IsoFileParams.Hostname
    $NetworkInterfaceName=$IsoFileParams.NetworkInterfaceName
    $IPAddressVM=$IsoFileParams.IPAddressVM
    $IPAddressGateway=$IsoFileParams.IPAddressGateway
    $UserName=$IsoFileParams.UserName
    $UserPwd=$IsoFileParams.UserPwd

    $downloadsFolder = $WorkingDirectoriesParams.DownloadsDirectory
    $provisioningFolder = $WorkingDirectoriesParams.ProvisioningDirectory

    $inProvisioningVhdxPath = "$provisioningFolder\$inProvisioningVhdxName"

    $vm = Get-VM | Where-Object Name -Like $vmName

    Write-Log "Ensure not existence of VM $vmName"
    if ($null -ne $vm) {
    	Stop-VirtualMachine($vm)
    	Remove-VirtualMachineForBaseImageProvisioning -Name $vmName -VhdxFilePath $inProvisioningVhdxPath
    }

    Write-Log "Ensure existence of directory $downloadsFolder"
    New-Folder $downloadsFolder | Out-Null

    Write-Log "Ensure existence of directory '$provisioningFolder'"
    New-Folder $provisioningFolder | Out-Null

    Write-Log "Create the base vhdx"
    New-VhdxDebianCloud -Proxy $Proxy -TargetFilePath $inProvisioningVhdxPath -DownloadsDirectory $downloadsFolder

    Write-Log "Create the iso file"
    $dnsEntries = Find-DnsIpAddress
    $isoContentParameterValues = [hashtable]@{
                                            Hostname=$Hostname
                                            NetworkInterfaceName=$NetworkInterfaceName
                                            IPAddressVM=$IPAddressVM
                                            IPAddressGateway=$IPAddressGateway
                                            IPAddressDnsServers=$dnsEntries
                                            UserName=$UserName
                                            UserPwd=$UserPwd
                                            }
    $isoFilePath = New-IsoFile -IsoFileCreatorToolPath $IsoFileCreatorToolPath `
                                -IsoFilePath "$provisioningFolder\$IsoFileName" `
                                -SourcePath $IsoContentTemplateSourcePath `
                                -IsoContentParameterValue $isoContentParameterValues
    $vmParams = @{
        "VmName"=$vmName
        "VhdxFilePath"=$inProvisioningVhdxPath
        "IsoFilePath"=$isoFilePath
        "VMMemoryStartupBytes"=$VMMemoryStartupBytes
        "VMProcessorCount"=$VMProcessorCount
        "VMDiskSize"=$VMDiskSize
    }
    New-VirtualMachineForBaseImageProvisioning @vmParams

    $vm = Get-VM -Name $vmName
    if ($vm -eq $null) {
        throw "The VM '$vmName' was not created."
    }

    Write-Log "Setup the network for provisioning the VM"

    Remove-NetworkForProvisioning -SwitchName $SwitchName -NatName $NatName
    $networkParams = @{
        "SwitchName"=$SwitchName
        "HostIpAddress"=$HostIpAddress
        "HostIpPrefixLength"=$HostIpPrefixLength
        "NatName"=$NatName
        "NatIpAddress"=$NatIpAddress
    }
    New-NetworkForProvisioning @networkParams

    Write-Log "Attach the VM to a network switch"
    Connect-VmToSwitch -VmName $vmName -SwitchName $SwitchName
}

<#
.SYNOPSIS
Stops a VM using its name.
.DESCRIPTION
The VM with the given name is stopped and awaited until its associated .avhdx file disappears from the file system.
The check for the file is done every 5 seconds for at most 30 times.
.PARAMETER Name
The name of the VM.
#>
function Stop-VirtualMachineForBaseImageProvisioning {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string] $Name = $(throw "Argument missing: Name")
    )
    $virtualMachine = Get-VM -Name $Name
    if ($virtualMachine -ne $null -and $virtualMachine.State -ne "Off") {
        Stop-VM -Name $Name
        $retryNumber = 0
        $maxAmountOfRetries = 3 * 10
        while (((Get-VMHardDiskDrive -VMName $Name).Path.Contains(".avhdx")) -and ($retryNumber -lt $maxAmountOfRetries)) {
            $retryNumber++
            Start-Sleep -Seconds 5
            $totalWaitingTime = 5 * $retryNumber
            Write-Log "Waiting since $totalWaitingTime seconds for VM to stop."
        }
    }
}

## Security

<#
.SYNOPSIS
Creates a new ssh key pair.
.DESCRIPTION
Creates a new ssh key pair.
.PARAMETER PrivateKeyPath
The full path of the file that will contain the private key.
#>
function New-SshKeyPair {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string] $PrivateKeyPath = $(throw "Argument missing: PrivateKeyPath")
    )
    # Create SSH keypair, if not yet available
    $sshDir = Split-Path -parent $PrivateKeyPath
    if (!(Test-Path $sshDir)) {
        mkdir $sshDir | Out-Null
    }
    if (!(Test-Path $PrivateKeyPath)) {
        Write-Log "creating SSH key $PrivateKeyPath"
        if ($PSVersionTable.PSVersion.Major -gt 5) {
            echo y | ssh-keygen.exe -t rsa -b 2048 -f $PrivateKeyPath -N '' | Write-Log
        } else {
            echo y | ssh-keygen.exe -t rsa -b 2048 -f $PrivateKeyPath -N '""' | Write-Log  # strange powershell syntax for empty passphrase...
        }
    }
    if (!(Test-Path $PrivateKeyPath)) {
        throw "unable to generate SSH keys ($PrivateKeyPath)"
    }
}

<#
.SYNOPSIS
Removes an ssh key from the 'knownhosts' file
.DESCRIPTION
Using the given IP address the corresponding entry is deleted from the file 'knownhosts'
.PARAMETER IpAddress
The IP address to look for and delete from the file.
#>
Function Remove-SshKeyFromKnownHostsFile {
    param (
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw "Argument missing: IpAddress")
    )
    #Invoke-Tool -ToolPath "ssh-keygen.exe" -Arguments "-R $IpAddress"
    ssh-keygen.exe -R $IpAddress 2>&1 | ForEach-Object { "$_" } | Write-Log
}

<#
.SYNOPSIS
Copies the public key file from the local computer to a remote computer.
.DESCRIPTION
Copies the public key file located in the local computer to a remote computer under the directory '~/.ssh/authorized_keys'
.PARAMETER UserName
The user name to log in into the remote computer.
.PARAMETER UserPwd
The password to log in into the remote computer.
.PARAMETER IpAddress
The IP address of the remote computer.
.PARAMETER LocalPublicKeyPath
The full path of the public key located on the local computer.
#>
function Copy-LocalPublicSshKeyToRemoteComputer() {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$UserName = $(throw "Argument missing: UserName"),
        [string]$UserPwd = $(throw "Argument missing: UserPwd"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw "Argument missing: IpAddress"),
        [ValidateScript({ Assert-LegalCharactersInPath -Path $_})]
        [string]$LocalPublicKeyPath = $(throw "Argument missing: LocalPublicKeyPath")
    )

    Assert-Path -Path $LocalPublicKeyPath -PathType 'Leaf' -ShallExist $true | Out-Null

    $user = "$UserName@$IpAddress"
    $userPwd = $UserPwd

    $localSourcePath = $LocalPublicKeyPath
    $publicKeyFileName = Split-Path -Path $localSourcePath -Leaf
    $targetPath = "/tmp/$publicKeyFileName"
    $remoteTargetPath = "$targetPath"
    Copy-ToControlPlaneViaUserAndPwd -Source $localSourcePath -Target $remoteTargetPath
    Invoke-CmdOnControlPlaneViaUserAndPwd "sudo mkdir -p ~/.ssh" -RemoteUser "$user" -RemoteUserPwd "$userPwd"
    Invoke-CmdOnControlPlaneViaUserAndPwd "sudo cat $targetPath | sudo tee ~/.ssh/authorized_keys" -RemoteUser "$user" -RemoteUserPwd "$userPwd"
}

## Network for provisioning

function New-NetworkForProvisioning {
    Param(
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$SwitchName = $(throw "Argument missing: SwitchName"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$HostIpAddress = $(throw "Argument missing: HostIpAddress"),
        [ValidateRange(0,32)]
        [uint16]$HostIpPrefixLength = $(throw "Argument missing: HostIpPrefixLength"),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$NatName = $(throw "Argument missing: NatName"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$NatIpAddress = $(throw "Argument missing: NatIpAddress")
    )

    $timeout = New-TimeSpan -Minutes 1
	$stpwatch = [System.Diagnostics.Stopwatch]::StartNew()
	do {
	    New-VMSwitch -Name $SwitchName -SwitchType Internal | Write-Log
        Write-Log "Try to find switch: $SwitchName"
    	$sw = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue | Write-Log
	} until ( ($sw) -or ($stpwatch.elapsed -lt $timeout))
	Write-Log "Created VMSwitch '$SwitchName'"

	New-NetIPAddress -IPAddress $HostIpAddress -PrefixLength $HostIpPrefixLength -InterfaceAlias "vEthernet ($SwitchName)" | Write-Log
	Write-Log "Added IP address '$HostIpAddress' to network interface named 'vEthernet ($SwitchName)'"

	$address = "$NatIpAddress/$HostIpPrefixLength"
    New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $address | Write-Log
	Write-Log "Created NetNat '$NatName' with address '$address'"
}

<#
.SYNOPSIS
Removes the network components used by the VM.
.DESCRIPTION
Removes the network components used by the VM.
.PARAMETER SwitchName
The name of the switch used by the VM.
.PARAMETER NatName
The name of the used NAT device.
#>
function Remove-NetworkForProvisioning {
    Param(
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$SwitchName = $(throw "Argument missing: SwitchName"),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$NatName = $(throw "Argument missing: NatName")
    )

	Write-Log "Removing NetNat '$NatName' if existing"
	Get-NetNat | Where-Object Name -Like $NatName | Remove-NetNat -Confirm:$false

	Write-Log "Removing VMSwitch '$SwitchName' if existing"
	Get-VMSwitch | Where-Object Name -Like $SwitchName | Select-Object -ExpandProperty Name | Remove-VMSwitch -Force
}

## HELPERS

Function Convert-Text {
    param (
        [string]$Source = $(throw "Argument missing: Source"),
        [hashtable]$ConversionTable = $(throw "Argument missing: ConversionTable")
    )
    $convertedSource = $Source
    foreach ($item in $ConversionTable.GetEnumerator() )
    {
        $convertedSource = $convertedSource -replace $item.Name,$item.Value
    }
    $convertedSource
}

Function Invoke-ScriptFile {
    param (
        [string]$ScriptPath = $(throw "Argument missing: ScriptPath"),
        [hashtable]$Params
    )

    &$ScriptPath @Params
}

Function Invoke-Tool {
    param (
        [string]$ToolPath = $(throw "Argument missing: ToolPath"),
        [string]$Arguments
    )

    $output = $(Start-Process -FilePath $ToolPath -ArgumentList $Arguments  -WindowStyle Hidden -Wait 2>&1 )

    if ($LASTEXITCODE -ne 0) {
        Write-Log $output
        throw "Tool '$ToolPath' returned code '$LASTEXITCODE'."
    }
}

Function New-Folder {
    param (
        [Parameter(Mandatory = $false, ValueFromPipeline=$true)]
        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [string]$Path
    )

    $pathAlreadyExists = Test-Path $Path -ErrorAction Stop
    if (!$pathAlreadyExists) {
    	New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }

    [PSCustomObject]@{
        Path = $Path
        Existed = $pathAlreadyExists
    }
}

Function Remove-FolderContent {
    param (
        [Parameter(Mandatory = $false, ValueFromPipeline=$true)]
        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [string]$Path
    )

    $pathExists = Test-Path $Path -ErrorAction Stop

    if ($pathExists) {
    	Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop | Out-Null
    } else {
        throw "The Path '$Path' does not exist"
    }

    $Path
}

<#
.SYNOPSIS
Copies a vhdx file from a source to a target location.
.DESCRIPTION
Copies a vhdx file from a source to a target location.
.PARAMETER SourceFilePath
The full path of the source vhdx file.
.PARAMETER TargetPath
The full path of the vhdx file after being copied.
#>
Function Copy-VhdxFile {
    param (
        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [ValidateScript({ Assert-Pattern -Path $_ -Pattern ".*\.vhdx$" })]
        [string] $SourceFilePath = $(throw "Argument missing: SourceFilePath"),

        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [ValidateScript({ Assert-Pattern -Path $_ -Pattern ".*\.vhdx$" })]
        [string] $TargetPath = $(throw "Argument missing: TargetPath")
    )
    Assert-Path -Path $SourceFilePath -PathType "Leaf" -ShallExist $true | Out-Null
    Assert-Path -Path $TargetPath -PathType "Leaf" -ShallExist $false | Out-Null
    Assert-Path -Path (Split-Path $TargetPath) -PathType "Container" -ShallExist $true | Out-Null

    Copy-Item -Path $SourceFilePath -Destination $TargetPath -Force -ErrorAction Stop | Out-Null
}

Function Assert-IsoContentParameters {
    param (
        [Parameter(Mandatory = $false)]
        [ValidateNotNull()]
        [Hashtable]$Parameter = $(throw 'Parameter missing: Parameter')
    )

    $isValidIPv4 = {
        param ([string]$value)
        $isValid = $true
        $parts = $value -split '\.'
        if ($parts.Count -eq 4) {
            foreach ($part in $parts) {
                try {
                    [int]$partAsInt = $part
                    if ($partAsInt -lt 0 -or $partAsInt -gt 255) {
                        $isValid = $false
                        break
                    }

                }
                catch {
                    $isValid = $false
                    break
                }

            }
        } else {
            $isValid = $false
        }

        $isValid
    }
    $validateKeyExists = {
        param ([string]$value)
        if (!($Parameter.ContainsKey($value))) {
            throw "Missing key: $value"
        }
    }

    &$validateKeyExists("Hostname")
    if ([string]::IsNullOrWhiteSpace($Parameter["Hostname"])) {
        throw 'Argument is null, empty or contain only white spaces: Hostname'
    }
    $hostname = $Parameter["Hostname"]
    if ([regex]::IsMatch($hostname, "[^a-z]+")) {
        throw 'Argument not valid: Hostname (only lowercase letters of the english alphabet are allowed)'
    }
    &$validateKeyExists("NetworkInterfaceName")
    if ([string]::IsNullOrWhiteSpace($Parameter["NetworkInterfaceName"])) {
        throw 'Argument is null, empty or contain only white spaces: NetworkInterfaceName'
    }
    &$validateKeyExists("IPAddressVM")
    if (!(&$isValidIPv4($Parameter["IPAddressVM"]))) {
        throw 'Argument is not valid IPv4: IPAddressVM'
    }
    &$validateKeyExists("IPAddressGateway")
    if (!(&$isValidIPv4($Parameter["IPAddressGateway"]))) {
        throw 'Argument is not valid IPv4: IPAddressGateway'
    }
    &$validateKeyExists("IPAddressDnsServers")
    $dnsServers = $Parameter["IPAddressDnsServers"] -split ","
    foreach ($dnsServer in $dnsServers) {
        if (!(&$isValidIPv4($dnsServer))) {
            throw 'Argument does not contain a valid IPv4: IPAddressDnsServers (only a comma separated list of IPv4 addresses is allowed)'
        }
    }
    &$validateKeyExists("UserName")
    if ([string]::IsNullOrWhiteSpace($Parameter["UserName"])) {
        throw 'Argument is null, empty or contain only white spaces: UserName'
    }
    &$validateKeyExists("UserPwd")
    if ($Parameter["UserPwd"] -eq $null) {
        throw 'Argument is null: UserPwd'
    }
    $True
}

Export-ModuleMember -Function New-RootfsForWSL, Find-DnsIpAddress, Remove-VirtualMachineForBaseImageProvisioning, Start-VirtualMachineAndWaitForHeartbeat, New-DebianCloudBasedVirtualMachine, Stop-VirtualMachineForBaseImageProvisioning, New-SshKeyPair, Remove-SshKeyFromKnownHostsFile, Copy-LocalPublicSshKeyToRemoteComputer, Remove-NetworkForProvisioning, Get-IsValidIPv4Address, Copy-VhdxFile


