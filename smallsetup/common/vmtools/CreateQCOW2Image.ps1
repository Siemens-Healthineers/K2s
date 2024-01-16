# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Creates a QCOW2 image from an Hyper-v VM Instance

.DESCRIPTION
...

.EXAMPLE
PS> .\CreateQCOW2Image.ps1 -Name Windows10CTColon -OutputPath d:\out


#>
Param(
    [parameter(Mandatory = $true, HelpMessage = 'Hyper-v VM Name')]
    [string] $Name,
    [parameter(Mandatory = $true, HelpMessage = 'QCOW2 VM Image output path')]
    [string] $OutputPath,
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy = ''
)

$mainStopwatch = [system.diagnostics.stopwatch]::StartNew()

# load global settings
&$PSScriptRoot\..\GlobalVariables.ps1
. $PSScriptRoot\..\GlobalFunctions.ps1

function Start-Executable {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [Alias('7za.exe')]
        [array]$Command
    )
    PROCESS {
        $cmdType = (Get-Command $Command[0]).CommandType
        if ($cmdType -eq 'Application') {
            $ErrorActionPreference = 'SilentlyContinue'
            $ret = & $Command[0] $Command[1..$Command.Length] 2>&1
            $ErrorActionPreference = 'Stop'
        }
        else {
            $ret = & $Command[0] $Command[1..$Command.Length]
        }
        if ($cmdType -eq 'Application' -and $LASTEXITCODE) {
            Throw ('Failed to run: ' + ($Command -Join ' '))
        }
        if ($ret -and $ret.Length -gt 0) {
            return $ret
        }
        return $false
    }
}

function Convert-VirtualDisk {
    Param(
        [Parameter(Mandatory = $true)]
        [string]$vhdPath,
        [Parameter(Mandatory = $true)]
        [string]$outPath,
        [Parameter(Mandatory = $true)]
        [string]$format,
        [Parameter(Mandatory = $false)]
        [boolean]$CompressQcow2
    )

    # download and install qemu-img
    $zipBase = 'qemu-img-win-x64-2_3_0.zip'
    $zipfile = Join-Path $global:KubernetesPath "SmallSetup\$zipBase"
    $url = "https://cloudbase.it/downloads/$zipBase"
    if (!(Test-Path $zipfile)) {
        Write-Output "Downloading $url...."
        Write-Output "to $zipfile"
        DownloadFile $zipfile $url $true $Proxy
        Write-Output "downloaded !"
    }
    else {
        Write-Output "Using existing $zipfile"
    }

    # Extract the archive.
    Write-Output "Extract archive to '$global:KubernetesPath\bin\exe'"
    Expand-Archive $zipfile -DestinationPath "$global:KubernetesPath\bin\exe" -Force     

    Write-Output "Convert Disk image: $vhdPath..."
    $format = $format.ToLower()
    $qemuParams = @("$global:KubernetesPath\bin\exe\qemu-img.exe", 'convert')
    if ($format -eq 'qcow2' -and $CompressQcow2) {
        Write-Output 'Qcow2 compression is enabled.'
        $qemuParams += @('-c', '-W', '-m16')
    }
    $qemuParams += @('-O', $format, $vhdPath, $outPath)
    Write-Output "Converting disk image from $vhdPath to $outPath with command $qemuParams ..."
    Start-Executable $qemuParams
    Write-Output "Convert disk image is finished."
}

Write-Output "Creating QCOW2 image file"

# The image file path that will be generated
$imageName = '\' + $Name + '.qcow2'
$qcow2DiskPath = Join-Path -Path $OutputPath -ChildPath $imageName
Write-Output "QCOW2 virtual disk path: " $qcow2DiskPath

try {
    
    [Environment]::CurrentDirectory = (Get-Location -PSProvider FileSystem).ProviderPath
    Write-Output "VM name is: " $Name
    $vm = Get-VM -VMName $Name -ErrorAction SilentlyContinue
    if ($Null -eq $vm) {
        throw ('VM {0} does not exist.' -f @($Name))
    }

    # start VM and connect to it
    Start-VM -Name $Name 
    # configure for remoting and set IP address
    Write-Output "Connect to VM $Name ..."
    $session1 = &"$global:KubernetesPath\smallsetup\common\vmtools\New-VMSession.ps1" -VMName $Name -AdministratorPassword $global:VMPwd -TimeoutInSeconds 20
    if ( ($session1) ) {
        Write-Output "Connected to VM $Name"
        Invoke-Command -Session $session1 {
            $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'up' }
            Write-Output "Adapter $adapter"
            $IPType = 'IPv4'
            $interface = $adapter | Get-NetIPInterface -AddressFamily $IPType
            Write-Output "Interface $interface"
            If ($interface.Dhcp -eq 'Disabled') {
                # Remove existing gateway
                If (($interface | Get-NetIPConfiguration).Ipv4DefaultGateway) {
                    $interface | Remove-NetRoute -Confirm:$false >$null 2>&1
                }
                # Enable DHCP
                $interface | Set-NetIPInterface -DHCP Enabled >$null 2>&1
                # Configure the DNS Servers automatically
                $interface | Set-DnsClientServerAddress -ResetServerAddresses >$null 2>&1
                Write-Output "Interface after changes: $interface"
            }
        }
    } else {
        Write-Output "VM $Name is probably a non Windows VM" 
    }

    # TODO: other actions in VM before exporting like removal of http proxies

    # stop VM in order to be able to create the qcow2 image
    Write-Output "Stop VM"
    Stop-VM -Name $Name -Force

    $disk = Get-VMHardDiskDrive -VMName $Name -ErrorAction SilentlyContinue
    if ($Null -eq $disk) {
        throw ('Failed to get VM disk path.' )
    }
    else {
        Write-Output "VM Disk path: " $disk.Path
    }

    $vhdxDiskPath = $disk.Path
    $file = Get-Item $vhdxDiskPath
    $fileExtension = $file.Extension

    if (!(($fileExtension -eq '.vhdx') -or ($fileExtension -eq '.vhd'))) {
        throw ('Disk is not a vhdx or vhd disk.' )
    }

    #Convert VHDX to QCOW2 image
    Write-Output "Converting VHDX to QCow2"
    Convert-VirtualDisk -VhdPath $vhdxDiskPath -outPath $qcow2DiskPath -format 'qcow2' `
        -CompressQcow2:$false
        
    Write-Output "Creation of QCow2 image generation is finished. Image path: $qcow2DiskPath"
}
catch { 
    Write-Output $_
    if (Test-Path $qcow2DiskPath) {
        Remove-Item -Force $qcow2DiskPath
    }
}

Write-Output "Total duration: $('{0:hh\:mm\:ss}' -f $mainStopwatch.Elapsed )"