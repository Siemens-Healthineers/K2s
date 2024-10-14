# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

$pathModule = "$PSScriptRoot\..\..\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\k2s.infra.module\log\log.module.psm1"
Import-Module $pathModule, $logModule

<#
.SYNOPSIS
    Checks whether a given VM is not in *off* state.
.DESCRIPTION
    Checks whether a given VM is not in *off* state.
.EXAMPLE
    Get-IsVmOperating -VmName "Test-VM"
.PARAMETER VmName
    Name of the VM to check
.OUTPUTS
    TRUE, if the state of the VM is other than '*Off*'
    FALSE, if the state is '*off*' or the VM was not found or multiple VMs with the same name exist.
#>
function Get-IsVmOperating {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $VmName = $(throw 'Please specify the VM you want to check.')
    )

    $private:vm = Get-VM | Where-Object Name -eq $VmName

    if (($private:vm | Measure-Object).Count -ne 1) {
        Write-Log "None or more than one VMs found for name '$VmName'."

        return $false
    }

    return $private:vm.State -notlike '*Off*'
}

<#
.SYNOPSIS
    Starts a given VM
.DESCRIPTION
    Starts a given VM specified by name and waits for the VM to be started, if desired.
.PARAMETER VmName
    Name of the VM to start
.PARAMETER Wait
    If set to TRUE, the function waits for the VM to reach the 'running' state.
.EXAMPLE
    Start-VirtualMachine -VmName "Test-VM"
.EXAMPLE
    Start-VirtualMachine -VmName "Test-VM" -Wait
    Waits for the VM to reach the 'running' state.
.NOTES
    The underlying function thrown an exception when the wait timeout is reached.
#>
function Start-VirtualMachine {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $VmName = $(throw 'Please specify the VM you want to start.'),
        [Parameter(Mandatory = $false)]
        [Switch]$Wait = $false
    )

    $private:vm = Get-VM | Where-Object Name -eq $VmName

    if (($private:vm | Measure-Object).Count -ne 1) {
        Write-Log "None or more than one VMs found for name '$VmName', aborting start."
        return
    }

    Write-Log "Starting VM '$VmName' ..."

    Start-VM -Name $VmName -WarningAction SilentlyContinue

    if ($Wait -eq $true) {
        Wait-ForDesiredVMState -VmName $VmName -State 'running'
    }

    Write-Log "VM '$VmName' started."
}

<#
.SYNOPSIS
    Stops a given VM
.DESCRIPTION
    Stops a given VM specified by name and waits for the VM to be stopped, if desired.
.PARAMETER VmName
    Name of the VM to stop
.PARAMETER Wait
    If set to TRUE, the function waits for the VM to reach the 'off' state.
.EXAMPLE
    Stop-VirtualMachine -VmName "Test-VM"
.EXAMPLE
    Stop-VirtualMachine -VmName "Test-VM" -Wait
    Waits for the VM to reach the 'off' state.
.NOTES
    The underlying function thrown an exception when the wait timeout is reached.
#>
function Stop-VirtualMachine {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $VmName = $(throw 'Please specify the VM you want to stop.'),
        [Parameter(Mandatory = $false)]
        [Switch]$Wait = $false
    )

    $private:vm = Get-VM | Where-Object Name -eq $VmName

    if (($private:vm | Measure-Object).Count -ne 1) {
        Write-Log "None or more than one VMs found for name '$VmName', aborting stop."
        return
    }

    Write-Log "Stopping VM '$VmName' ..."

    Stop-VM -Name $VmName -Force -WarningAction SilentlyContinue

    if ($Wait -eq $true) {
        Wait-ForDesiredVMState -VmName $VmName -State 'off'
    }

    Write-Log "VM '$VmName' stopped."
}

<#
.Description
Restart-VM restarts the VM and wait till it's available.
#>
function Restart-VirtualMachine($VMName, $VmPwd) {
    # restart VM
    Write-Log "Restart VM $VMName"
    $i = 0;
    while ($true) {
        $i++
        Write-Log "VM Handling loop (iteration #$i):"
        Start-Sleep -s 1

        if ( $i -eq 1 ) {
            Write-Log "           stopping VM ($i)"
            Stop-VM -Name $VMName -Force -WarningAction SilentlyContinue

            $state = (Get-VM -Name $VMName).State -eq [Microsoft.HyperV.PowerShell.VMState]::Off
            while (!$state) {
                Write-Log '           still waiting for stop...'
                Start-Sleep -s 1
            }

            Write-Log "           re-starting VM ($i)"
            Start-VM -Name $VMName
            Start-Sleep -s 4
        }

        $con = New-VMSession -VMName $VMName -AdminPwd $VmPwd
        if ($con) {
            Write-Log "           connect succeeded to $VMName VM"
            break;
        }
    }
}

<#
.SYNOPSIS
    Removes a given VM completely
.DESCRIPTION
    Removes a given VM and it's virtual disk if desired.
.PARAMETER VmName
    Name of the VM to remove
.PARAMETER DeleteVirtualDisk
    Indicating whether the VM's virtual disk should be removed as well (default: TRUE).
.EXAMPLE
    Remove-VirtualMachine -VmName "Test-VM"
    Deletes the VM and it's virtual disk
.EXAMPLE
    Remove-VirtualMachine -VmName "Test-VM" -DeleteVirtualDisk $false
    Deletes the VM but not it's virtual disk
#>
function Remove-VirtualMachine {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $VmName = $(throw 'Please specify the VM you want to remove.'),
        [Parameter()]
        [bool] $DeleteVirtualDisk = $true
    )

    $private:vm = Get-VM | Where-Object Name -eq $VmName

    if (($private:vm | Measure-Object).Count -ne 1) {
        Write-Log "None or more than one VMs found for name '$VmName', aborting removal."
        return
    }

    if ($DeleteVirtualDisk) {
        Remove-VMSnapshots -Vm $private:vm
    }

    $hardDiskPath = ($private:vm | Select-Object -ExpandProperty HardDrives).Path

    Write-Log "Removing VM '$VmName' ($($private:vm.VMId)) ..."
    Remove-VM -Name $VmName -Force
    Write-Log "VM '$VmName' removed."

    if ($DeleteVirtualDisk) {
        Write-Log "Removing hard disk '$hardDiskPath' ..."

        Remove-Item -Path $hardDiskPath -Force

        Write-Log "Hard disk '$hardDiskPath' removed."
    }
    else {
        Write-Log "Keeping virtual disk '$hardDiskPath'."
    }
}

<#
.SYNOPSIS
    Removes all snapshots of a given VM
.DESCRIPTION
    Removes all snapshots of a given VM and waits for the virtual disks to merge
.PARAMETER Vm
    The VM of which the snapshots shall be removed
.EXAMPLE
    $vm = Get-VM | Where-Object Name -eq "my-VM"
    Remove-VMSnapshots -Vm $vm
#>
function Remove-VMSnapshots {
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [Microsoft.HyperV.PowerShell.VirtualMachine] $Vm = $(throw 'Please specify the VM of which you want to remove the snapshots.')
    )

    Write-Log 'Removing VM snapshots ...'

    Get-VMSnapshot -VMName $Vm.Name | Remove-VMSnapshot

    Write-Log 'Waiting for disks to merge ...'

    while ($Vm.Status -eq 'merging disks') {
        Write-Log '.'

        Start-Sleep -Milliseconds 500
    }

    # give the VM object time to refresh it's virtual disk path property
    Start-Sleep -Milliseconds 500

    Write-Log ''
    Write-Log 'VM snapshots removed.'
}

<#
.SYNOPSIS
    Waits for a given VM to get into a given state.
.DESCRIPTION
    Waits for a given VM to get into a given state. The timeout is configurable.
.PARAMETER VmName
    Name of the VM to wait for
.PARAMETER State
    Desired state
.PARAMETER TimeoutInSeconds
    Timeout in seconds. Default is 360.
.EXAMPLE
    Wait-ForDesiredVMState -VmName 'Test-VM' -State 'off'
    Waits for the VM to be shut down.
.EXAMPLE
    Wait-ForDesiredVMState -VmName 'Test-VM' -TimeoutInSeconds 30 -State 'off'
    Wait max. 30 seconds until the VM must be shut down.
.NOTES
    Throws exception if VM was not found or more than one VMs with the given name exist.
    Throws exception if the desired state is invalid. State names are checked case-insensitive.
#>
function Wait-ForDesiredVMState {
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $VmName = $(throw 'Please specify the VM you want to wait for.'),
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $State = $(throw 'Please specify the desired VM state.'),
        [Parameter(Mandatory = $false)]
        [int]$TimeoutInSeconds = 360
    )

    $secondsIncrement = 1
    $elapsedSeconds = 0

    if ([System.Enum]::GetValues([Microsoft.HyperV.PowerShell.VMState]) -notcontains $State) {
        throw "'$State' is an invalid VM state!"
    }

    Write-Log "Waiting for VM '$VmName' to be in state '$State' (timeout: $($TimeoutInSeconds)s) ..."

    $private:vm = Get-VM | Where-Object Name -eq $VmName

    if (($private:vm | Measure-Object).Count -ne 1) {
        throw "None or more than one VMs found for name '$VmName', aborting!"
    }

    while (($private:vm.State -ne $State) -and ($elapsedSeconds -lt $TimeoutInSeconds)) {
        Start-Sleep -Seconds $secondsIncrement

        $elapsedSeconds += $secondsIncrement

        Write-Log "$($elapsedSeconds)s.." -Progress
    }

    if ( $elapsedSeconds -gt 0) {
        Write-Log '.' -Progress
    }

    if ($elapsedSeconds -ge $TimeoutInSeconds) {
        throw "VM '$VmName' did'nt reach the desired state '$State' within the time frame of $($TimeoutInSeconds)s!"
    }
}


function Get-VirtioImage {
    [CmdletBinding()]
    param(
        [string]$OutputPath,
        [string]$Proxy = ''
    )
    $urlRoot = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/'
    $urlFile = 'virtio-win.iso'

    $url = "$urlRoot/$urlFile"

    if (-not $OutputPath) {
        $OutputPath = Get-Item '.\'
    }

    $imgFile = Join-Path $OutputPath $urlFile

    if ([System.IO.File]::Exists($imgFile)) {
        Write-Log "File '$imgFile' already exists. Nothing to do."
    }
    else {
        Write-Log "Downloading file '$imgFile'..."

        # Enables TLS 1.2
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $client = New-Object System.Net.WebClient

        if ($Proxy -ne '') {
            Write-Log "Using Proxy $Proxy to download $url"
            $webProxy = New-Object System.Net.WebProxy($Proxy)
            $webProxy.UseDefaultCredentials = $true
            $client.Proxy = $webProxy
        }

        $client.DownloadFile($url, $imgFile)
    }

    return $imgFile
}

function New-WinUnattendFile {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AdminPwd,

        [Parameter(Mandatory = $true)]
        [string]$WinVersionKey,

        [string]$VMName,

        [string]$FilePath,

        [string]$Locale
    )

    $ErrorActionPreference = 'Stop'

    $winTemplate = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" publicKeyToken="31bf3856ad364e35" processorArchitecture="amd64" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <ProductKey></ProductKey>
            <ComputerName></ComputerName>
        </component>
        <component name="Microsoft-Windows-International-Core" publicKeyToken="31bf3856ad364e35" language="neutral" processorArchitecture="amd64" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <InputLocale></InputLocale>
            <SystemLocale></SystemLocale>
            <UserLocale></UserLocale>
        </component>
        <component name="Microsoft-Windows-Security-SPP-UX" publicKeyToken="31bf3856ad364e35" language="neutral" processorArchitecture="amd64" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <SkipAutoActivation>true</SkipAutoActivation>
        </component>
        <component name="Microsoft-Windows-SQMApi" publicKeyToken="31bf3856ad364e35" language="neutral" processorArchitecture="amd64" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <CEIPEnabled>0</CEIPEnabled>
        </component>
        <component name="Microsoft-Windows-Deployment" publicKeyToken="31bf3856ad364e35" language="neutral" processorArchitecture="amd64" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>net user administrator /active:yes</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" processorArchitecture="amd64" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <OOBE>
                <SkipMachineOOBE>true</SkipMachineOOBE>
                <HideEULAPage>true</HideEULAPage>
                <SkipUserOOBE>true</SkipUserOOBE>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <ProtectYourPC>3</ProtectYourPC>
                <HideLocalAccountScreen>true</HideLocalAccountScreen>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>

            </OOBE>
            <UserAccounts>
                <AdministratorPassword>
                    <Value></Value>
                    <PlainText>false</PlainText>
                </AdministratorPassword>
            </UserAccounts>
        </component>
    </settings>
</unattend>
'@

    $winXmlFile = [xml]$winTemplate

    if (-not $FilePath) {
        $FilePath = Join-Path $env:TEMP 'unattend.xml'
    }

    if ($VMName) {
        $winXmlFile.unattend.settings[0].component[0].ComputerName = $VMName
    }

    $encodedPassword = [System.Text.Encoding]::Unicode.GetBytes($AdminPwd + 'AdministratorPassword')
    $winXmlFile.unattend.settings[1].component.UserAccounts.AdministratorPassword.Value = [Convert]::ToBase64String($encodedPassword)

    $winXmlFile.unattend.settings[0].component[0].ProductKey = $WinVersionKey

    if ($Locale) {
        $winXmlFile.unattend.settings[0].component[1].InputLocale = $Locale
        $winXmlFile.unattend.settings[0].component[1].SystemLocale = $Locale
        $winXmlFile.unattend.settings[0].component[1].UserLocale = $Locale
    }

    $xmlTextWriter = New-Object System.XMl.XmlTextWriter($FilePath, [System.Text.Encoding]::UTF8)
    $xmlTextWriter.Formatting = [System.Xml.Formatting]::Indented
    $winXmlFile.Save($xmlTextWriter)
    $xmlTextWriter.Dispose()

    return $FilePath
}

function Add-IsoImage([string]$IsoFileName, [scriptblock]$ScriptBlock) {
    $IsoFileName = (Resolve-Path $IsoFileName).Path

    Write-Log "Mounting '$IsoFileName'..."
    $mountedImage = Mount-DiskImage -ImagePath $IsoFileName -StorageType ISO -PassThru
    try {
        $driveLetter = ($mountedImage | Get-Volume).DriveLetter
        Invoke-Command $ScriptBlock -ArgumentList $driveLetter
    }
    finally {
        Write-Log "Dismounting '$IsoFileName'..."
        Dismount-DiskImage -ImagePath $IsoFileName | Out-Null
    }
}

function Add-WindowsImage([string]$ImagePath, [int]$ImageIndex, [string]$VirtioDriveLetter, [scriptblock]$ScriptBlock) {
    $mountPath = Join-Path ([System.IO.Path]::GetTempPath()) 'winmount\'

    Write-Log "Mounting '$ImagePath' ($ImageIndex)..."
    mkdir $mountPath -Force | Out-Null
    Mount-WindowsImage -Path $mountPath -ImagePath $ImagePath -Index $ImageIndex | Out-Null
    try {
        Invoke-Command $ScriptBlock -ArgumentList $mountPath
    }
    finally {
        Write-Log "Dismounting '$ImagePath' ($ImageIndex)..."
        Dismount-WindowsImage -Path $mountPath -Save | Out-Null
    }
}

function Add-DriversToWindowsImage($ImagePath, $ImageIndex, $VirtioDriveLetter) {
    Add-WindowsImage -ImagePath $ImagePath -ImageIndex $ImageIndex -VirtioDriveLetter $VirtioDriveLetter {
        Param($mountPath)

        Write-Log "  Adding driver 'vioscsi'..."
        Add-WindowsDriver -Path $mountPath -Driver "$($VirtioDriveLetter):\vioscsi\w10\amd64" -Recurse -ForceUnsigned

        Write-Log "  Adding driver 'NetKVM'..."
        Add-WindowsDriver -Path $mountPath -Driver "$($VirtioDriveLetter):\NetKVM\w10\amd64" -Recurse -ForceUnsigned

        Write-Log "  Adding driver 'Balloon'..."
        Add-WindowsDriver -Path $mountPath -Driver "$($VirtioDriveLetter):\Balloon\w10\amd64" -Recurse -ForceUnsigned

        Write-Log "  Adding driver 'pvpanic'..."
        Add-WindowsDriver -Path $mountPath -Driver "$($VirtioDriveLetter):\pvpanic\w10\amd64" -Recurse -ForceUnsigned

        Write-Log "  Adding driver 'qemupciserial'..."
        Add-WindowsDriver -Path $mountPath -Driver "$($VirtioDriveLetter):\qemupciserial\w10\amd64" -Recurse -ForceUnsigned

        Write-Log "  Adding driver 'qxldod'..."
        Add-WindowsDriver -Path $mountPath -Driver "$($VirtioDriveLetter):\qxldod\w10\amd64" -Recurse -ForceUnsigned

        Write-Log "  Adding driver 'vioinput'..."
        Add-WindowsDriver -Path $mountPath -Driver "$($VirtioDriveLetter):\vioinput\w10\amd64" -Recurse -ForceUnsigned

        Write-Log "  Adding driver 'viorng'..."
        Add-WindowsDriver -Path $mountPath -Driver "$($VirtioDriveLetter):\viorng\w10\amd64" -Recurse -ForceUnsigned

        Write-Log "  Adding driver 'vioserial'..."
        Add-WindowsDriver -Path $mountPath -Driver "$($VirtioDriveLetter):\vioserial\w10\amd64" -Recurse -ForceUnsigned

        Write-Log "  Adding driver 'viostor'..."
        Add-WindowsDriver -Path $mountPath -Driver "$($VirtioDriveLetter):\viostor\w10\amd64" -Recurse -ForceUnsigned
    }
}

function Add-VirtioDrivers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VirtioIsoPath,

        [Parameter(Mandatory = $true)]
        [string]$ImagePath,

        [int]$ImageIndex = 1
    )

    Add-IsoImage -IsoFileName $VirtioIsoPath {
        Param($virtioDriveLetter)

        $virtioInstaller = "$($virtioDriveLetter):\virtio-win-gt-x64.msi"
        $exists = Test-Path $virtioInstaller
        if (-not $exists) {
            throw 'The specified ISO does not appear to be a valid Virtio installation media.'
        }

        Write-Log "Add: $ImagePath with index: $ImageIndex and drive letter: $virtioDriveLetter"
        Add-DriversToWindowsImage -ImagePath $ImagePath -ImageIndex $ImageIndex -VirtioDriveLetter $virtioDriveLetter
    }

}

function
Convert-WinImage {
    <#
    .SYNOPSIS
        Minimalistic Script to Create a bootable VHD(X) based on Windows 10 installation media.
        See https://github.com/Microsoft/Virtualization-Documentation/tree/master/hyperv-tools/Convert-WindowsImage

    .EXAMPLE
        .\Convert-WinImage.ps1 -IsoPath D:\foo\install.wim -Edition Professional -DiskLayout UEFI

        This command will create a 40GB dynamically expanding VHD in a WorkingDirectory.
        The VHD will be based on the Professional edition from Source ISO, and will be named automatically.

    .OUTPUTS
        System.IO.FileInfo if PassThru is enabled
    #>
    #Requires -RunAsAdministrator

    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ Test-Path $(Resolve-Path $_) })]
        $IsoPath,

        [string[]]
        [ValidateNotNullOrEmpty()]
        $WinEdition,

        [string]
        [ValidateNotNullOrEmpty()]
        $VHDPath,

        [UInt64]
        [ValidateNotNullOrEmpty()]
        [ValidateRange(1GB, 64TB)]
        $SizeBytes = 25GB,

        [string]
        [ValidateNotNullOrEmpty()]
        [ValidateSet('VHD', 'VHDX', 'AUTO')]
        $VHDFormat = 'AUTO',

        [Parameter(Mandatory = $true)]
        [string]
        [ValidateNotNullOrEmpty()]
        [ValidateSet('BIOS', 'UEFI', 'WindowsToGo')]
        $DiskLayout,

        [string]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ Test-Path $(Resolve-Path $_) })]
        $UnattendDir,

        [string]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ Test-Path $_ })]
        $WorkingDir = $pwd,

        [string]
        [ValidateNotNullOrEmpty()]
        $TempDir = $env:Temp,

        [switch]
        $CacheSrc = $false,

        [switch]
        $Passthru
    )

    Begin {
        #Logging Variables
        $scriptName = 'Convert-WinImage'
        $sessionKey = [Guid]::NewGuid().ToString()
        $logDir = "$($TempDir)\$($scriptName)\$($sessionKey)"

        #VHD Limits and Supported Version
        $vhdMaxSize = 2040GB
        $lowestSupportedBuild = 9200

        $winBuildNumber = [int]($(Get-CimInstance -Class Win32_OperatingSystem).BuildNumber)
        $VHDFormat = $VHDFormat.ToUpper()

        Function Run-Exe {
            param([string]$Executable, [string[]]$ExeArgs, [int]$ExpectedExitCode = 0)

            Write-Log "Running EXE $Executable with args: $ExeArgs"
            $exeProc = Start-Process           `
                -FilePath $Executable      `
                -ArgumentList $ExeArgs     `
                -NoNewWindow               `
                -RedirectStandardError "$($TempDir)\$($scriptName)\$($sessionKey)\$($Executable)-StandardError.txt"  `
                -RedirectStandardOutput "$($TempDir)\$($scriptName)\$($sessionKey)\$($Executable)-StandardOutput.txt" `
                -Passthru

            $execHandle = $exeProc.Handle # WORKAROUND!! POWERSHELL BUG https://github.com/PowerShell/PowerShell/issues/20716, Need to cache handle in order to get the exit code.
            $exeProc.WaitForExit()

            Write-Log "Executable Return Code: $($exeProc.ExitCode)."

            if ($exeProc.ExitCode -ne $ExpectedExitCode) {
                throw "$Executable execution failed with code $($exeProc.ExitCode)"
            }
        }

        Function Test-IsNetPath
        {
            param([string]$Path)

            try {
                $uri = New-Object System.Uri -ArgumentList $Path

                if ($uri.IsUnc) {
                    return $true
                }

                $drive = Get-PSDrive -PSProvider 'FileSystem' -Name ($uri.LocalPath.Substring(0, 1)) -ErrorAction Stop

                if ($drive.Root -like '\\*') {
                    return $true
                }
            }
            catch {
                Write-Error "Invalid path: $_"
            }

            return $false
        }
    }

    Process {

        $vhdDiskNumber = $null
        $openIso = $null
        $wim = $null
        $vhdFinalName = $null
        $vhdFinalPath = $null
        $isoFinalPath = $null
        $tempSource = $null
        $BCDBoot = 'bcdboot.exe'

        Write-Log "Source Path $IsoPath..."

        if (Get-Command Get-WindowsOptionalFeature -ErrorAction SilentlyContinue) {
            try {
                $hyperVEnabled = $((Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V).State -eq 'Enabled')
            }
            catch {
                $hyperVEnabled = $false
            }
        }
        else {
            $hyperVEnabled = $false
        }

        $vhd = @()

        try {
            if (Test-Path $logDir) {
                $null = Remove-Item $logDir -Force -Recurse
            }

            $null = mkdir $logDir -Force

            if (!($winBuildNumber -ge [int]$lowestSupportedBuild)) {
                throw "$scriptName requires Windows 8 or higher."
            }

            if ($VHDFormat -ilike 'AUTO') {
                if ($DiskLayout -eq 'BIOS') {
                    $VHDFormat = 'VHD'
                }
                else {
                    $VHDFormat = 'VHDX'
                }
            }

            if (![string]::IsNullOrEmpty($UnattendDir)) {
                $UnattendDir = (Resolve-Path $UnattendDir).Path
            }

            # We assign smallest supported block size for Dynamic VHD(X)
            $VHDBlockSizeBytes = 1MB

            if ('VHD' -ilike $VHDFormat) {
                if ($SizeBytes -gt $vhdMaxSize) {
                    Write-Warning "For the VHD file format, the maximum file size is ~2040GB.  We will automatically set size to 2040GB..."
                    $SizeBytes = $vhdMaxSize
                }

                $VHDBlockSizeBytes = 512KB
            }


            if ((![String]::IsNullOrEmpty($VHDPath)) -and (![String]::IsNullOrEmpty($WorkingDir))) {
                if ($WorkingDir -ne $pwd) {
                    Write-Warning 'Ignoring the WorkingDirectory specification. Specifying -VHDPath and -WorkingDirectory at the same time is contradictory!'
                    $WorkingDir = Split-Path $VHDPath -Parent
                }
            }

            if ($VHDPath) {
                $fileExt = ([IO.FileInfo]$VHDPath).Extension
                if (!($fileExt -ilike ".$($VHDFormat)")) {
                    throw "There is a mismatch between the file extensions VHDPath file ext: ($($fileExt.ToUpper())), and VHDFormat: (.$($VHDFormat)). Ensure that they match and try again"
                }
            }

            # Creating a temporary name for the VHD(x). We shall name it at the end of the script.
            if ([String]::IsNullOrEmpty($VHDPath)) {
                $VHDPath = Join-Path $WorkingDir "$($sessionKey).$($VHDFormat.ToLower())"
            }
            else {
                if (![IO.Path]::IsPathRooted($VHDPath)) {
                    $VHDPath = Join-Path $WorkingDir $VHDPath
                }

                $vhdFinalName = Split-Path $VHDPath -Leaf
                $VHDPath = Join-Path (Split-Path $VHDPath -Parent) "$($sessionKey).$($VHDFormat.ToLower())"
            }

            Write-Log "Temporary $VHDFormat path is : $VHDPath"

            # Here if input is an ISO, first mount it and obtain the path to the WIM file.
            if (([IO.FileInfo]$IsoPath).Extension -ilike '.ISO') {
                # If the ISO isn't local, copy it down.
                if (Test-IsNetPath $IsoPath) {
                    Write-Log "Copying ISO $(Split-Path $IsoPath -Leaf) to temp folder..."
                    robocopy $(Split-Path $IsoPath -Parent) $TempDir $(Split-Path $IsoPath -Leaf) | Out-Null
                    $IsoPath = "$($TempDir)\$(Split-Path $IsoPath -Leaf)"

                    $tempSource = $IsoPath
                }

                $isoFinalPath = (Resolve-Path $IsoPath).Path

                Write-Log "Opening ISO $(Split-Path $isoFinalPath -Leaf)..."
                $openIso = Mount-DiskImage -ImagePath $isoFinalPath -StorageType ISO -PassThru
                $openIso = Get-DiskImage -ImagePath $isoFinalPath
                $driveLetter = ($openIso | Get-Volume).DriveLetter

                $IsoPath = "$($driveLetter):\sources\install.wim"

                Write-Log "Looking for $($IsoPath)..."
                if (!(Test-Path $IsoPath)) {
                    throw 'The specified ISO does not appear to be valid Windows installation media.'
                }
            }

            if (Test-IsNetPath $IsoPath) {
                Write-Log "Copying WIM $(Split-Path $IsoPath -Leaf) to temp folder..."
                robocopy $(Split-Path $IsoPath -Parent) $TempDir $(Split-Path $IsoPath -Leaf) | Out-Null
                $IsoPath = "$($TempDir)\$(Split-Path $IsoPath -Leaf)"
                $tempSource = $IsoPath
            }

            $IsoPath = (Resolve-Path $IsoPath).Path

            # Now lets query wim information and obtain the index of targeted image

            Write-Log 'Searching for requested Windows Image in the WIM file'
            $WindowsImage = Get-WindowsImage -ImagePath $IsoPath

            if (-not $WindowsImage -or ($WindowsImage -is [System.Array])) {
                $WinEditionIndex = 0;
                if ([Int32]::TryParse($WinEdition, [ref]$WinEditionIndex)) {
                    $WindowsImage = Get-WindowsImage -ImagePath $IsoPath -Index $WinEditionIndex
                }
                else {
                    $WindowsImage = Get-WindowsImage -ImagePath $IsoPath | Where-Object { $_.ImageName -ilike "*$($WinEdition)" }
                }

                if (-not $WindowsImage) {
                    throw 'Requested windows Image was not found on the WIM file!'
                }

                if ($WindowsImage -is [System.Array]) {
                    Write-Log "WIM file has the following $($WindowsImage.Count) images that match filter *$($WinEdition)"
                    Get-WindowsImage -ImagePath $IsoPath

                    Write-Error 'You must specify an Edition or SKU index, since the WIM has more than one image.'
                    throw "There are more than one images that match ImageName filter *$($WinEdition)"
                }
            }

            $ImageIndex = $WindowsImage[0].ImageIndex

            $wim = Get-WindowsImage -ImagePath $IsoPath -Index $ImageIndex

            if ($null -eq $wim) {
                Write-Error 'The specified edition does not appear to exist in the specified WIM.'
                throw
            }

            Write-Log "Image $($wim.ImageIndex) selected ($($wim.EditionId))..."

            if ($hyperVEnabled) {
                Write-Log 'Creating VHD sparse disk...'
                $newVhd = New-VHD -Path $VHDPath -SizeBytes $SizeBytes -BlockSizeBytes $VHDBlockSizeBytes -Dynamic

                Write-Log "Mounting $VHDFormat and Getting Disk..."
                $vhdDisk = $newVhd | Mount-VHD -PassThru | Get-Disk
                $vhdDiskNumber = $vhdDisk.Number
            }
            else {
                throw "Convert-WindowsImage only supports Hyper-V based VHD creation."
            }

            switch ($DiskLayout) {
                'BIOS' {
                    Write-Log 'Initializing disk...'
                    Initialize-Disk -Number $vhdDiskNumber -PartitionStyle MBR

                    # Create the Windows/system partition
                    Write-Log 'Creating single partition...'
                    $systemPartition = New-Partition -DiskNumber $vhdDiskNumber -UseMaximumSize -MbrType IFS -IsActive
                    $windowsPartition = $systemPartition

                    Write-Log 'Formatting windows volume...'
                    $systemVolume = Format-Volume -Partition $systemPartition -FileSystem NTFS -Force -Confirm:$false
                    $windowsVolume = $systemVolume
                }

                'UEFI' {
                    Write-Log 'Initializing disk...'
                    Initialize-Disk -Number $vhdDiskNumber -PartitionStyle GPT

                    if (($winBuildNumber) -ge 10240) {
                        # Create the system partition.  Create a data partition so we can format it, then change to ESP
                        Write-Log 'Creating EFI system partition...'
                        $systemPartition = New-Partition -DiskNumber $vhdDiskNumber -Size 200MB -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'

                        Write-Log 'Formatting system volume...'
                        $systemVolume = Format-Volume -Partition $systemPartition -FileSystem FAT32 -Force -Confirm:$false

                        Write-Log 'Setting system partition as ESP...'
                        $systemPartition | Set-Partition -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
                        $systemPartition | Add-PartitionAccessPath -AssignDriveLetter
                    }
                    else {
                        # Create the system partition
                        Write-Log 'Creating EFI system partition (ESP)...'
                        $systemPartition = New-Partition -DiskNumber $vhdDiskNumber -Size 200MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -AssignDriveLetter

                        Write-Log 'Formatting ESP...'
                        # /Q Quick format, /Y Suppress Prompt, /FS File System
                        $formatArgs = @("$($systemPartition.DriveLetter):", '/FS:FAT32', '/Q', '/Y')

                        Run-Exe -Executable format -ExeArgs $formatArgs
                    }

                    # Create the reserved partition
                    Write-Log 'Creating MSR partition...'
                    New-Partition -DiskNumber $vhdDiskNumber -Size 128MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'

                    # Create the Windows partition
                    Write-Log 'Creating windows partition...'
                    $windowsPartition = New-Partition -DiskNumber $vhdDiskNumber -UseMaximumSize -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'

                    Write-Log 'Formatting windows volume...'
                    $windowsVolume = Format-Volume -Partition $windowsPartition -FileSystem NTFS -Force -Confirm:$false
                }

                'WindowsToGo' {
                    Write-Log 'Initializing disk...'
                    Initialize-Disk -Number $vhdDiskNumber -PartitionStyle MBR

                    Write-Log 'Creating system partition...'
                    $systemPartition = New-Partition -DiskNumber $vhdDiskNumber -Size 350MB -MbrType FAT32 -IsActive

                    Write-Log 'Formatting system volume...'
                    $systemVolume = Format-Volume -Partition $systemPartition -FileSystem FAT32 -Force -Confirm:$false

                    Write-Log 'Creating windows partition...'
                    $windowsPartition = New-Partition -DiskNumber $vhdDiskNumber -UseMaximumSize -MbrType IFS

                    Write-Log 'Formatting windows volume...'
                    $windowsVolume = Format-Volume -Partition $windowsPartition -FileSystem NTFS -Force -Confirm:$false
                }
            }

            # Assign drive letter to Windows partition.  This is required for bcdboot.
            $attempts = 1
            $assigned = $false

            do {
                $windowsPartition | Add-PartitionAccessPath -AssignDriveLetter
                $windowsPartition = $windowsPartition | Get-Partition
                if ($windowsPartition.DriveLetter -ne 0) {
                    $assigned = $true
                }
                else {
                    #sleep for up to 10 seconds and retry
                    Get-Random -Minimum 1 -Maximum 10 | Start-Sleep

                    $attempts++
                }
            }
            while ($attempts -le 25 -and -not($assigned))

            if (-not($assigned)) {
                throw 'Unable to get Partition after retry'
            }

            $windowsDrive = $(Get-Partition -Volume $windowsVolume).AccessPaths[0].substring(0, 2)
            Write-Log "Windows path ($windowsDrive) has been assigned."
            Write-Log "Windows path ($windowsDrive) took $attempts attempts to be assigned."

            # Refresh access paths (we have now formatted the volume)
            $systemPartition = $systemPartition | Get-Partition
            $systemDrive = $systemPartition.AccessPaths[0].trimend('\').replace('\?', '??')
            Write-Log "System volume location: $systemDrive"

            # APPLY IMAGE FROM WIM TO THE NEW VHD WHICH IS CREATED

            Write-Log "Applying image in format $VHDFormat. This will take a while..."
            if ((Get-Command Expand-WindowsImage -ErrorAction SilentlyContinue)) {
                Expand-WindowsImage -ApplyPath $windowsDrive -ImagePath $IsoPath -Index $ImageIndex -LogPath "$($logDir)\DismLogs.log" | Out-Null
            }
            else {
                throw 'Image Apply failed! See DismImageApply logs for details'
            }
            Write-Log 'Image was applied successfully. '

            # Copy the unattend file
            if (![string]::IsNullOrEmpty($UnattendDir)) {
                Write-Log "Applying unattend file ($(Split-Path $UnattendDir -Leaf))..."
                Copy-Item -Path $UnattendDir -Destination (Join-Path $windowsDrive 'unattend.xml') -Force
            }

            $wimArchitecture = ($wim | Out-String -Stream | Select-String Architecture | Out-String | ForEach-Object {$_ -replace '.*:', ''}).Trim()
            Write-Log "Win VM Arch found $wimArchitecture ..."

            if (($wimArchitecture -ne 'ARM') -and ($wimArchitecture -ne 'ARM64')) {
                if (Test-Path "$($systemDrive)\boot\bcd") {
                    Write-Log 'Image already has BIOS BCD store...'
                }
                elseif (Test-Path "$($systemDrive)\efi\microsoft\boot\bcd") {
                    Write-Log 'Image already has EFI BCD store...'
                }
                else {
                    Write-Log 'Making image bootable...'
                    # Path to the \Windows on the VHD, Specifies the volume letter of the drive to create the \BOOT folder on.
                    $bcdBootArgs = @("$($windowsDrive)\Windows", "/s $systemDrive", '/v')

                    # Add firmware type option of the target system partition
                    switch ($DiskLayout) {
                        'BIOS' {
                            $bcdBootArgs += '/f BIOS'
                        }

                        'UEFI' {
                            $bcdBootArgs += '/f UEFI'
                        }

                        'WindowsToGo' {
                            if (Test-Path "$($windowsDrive)\Windows\boot\EFI\bootmgfw.efi") {
                                $bcdBootArgs += '/f ALL'
                            }
                        }
                    }

                    Run-Exe -Executable $BCDBoot -ExeArgs $bcdBootArgs

                    if ($DiskLayout -eq 'BIOS') {
                        Write-Log "Fixing the Device ID in the BCD store on $($VHDFormat)..."
                        Run-Exe -Executable 'BCDEDIT.EXE' -ExeArgs ("/store $($systemDrive)\boot\bcd", "/set `{bootmgr`} device locate")
                        Run-Exe -Executable 'BCDEDIT.EXE' -ExeArgs ("/store $($systemDrive)\boot\bcd", "/set `{default`} device locate")
                        Run-Exe -Executable 'BCDEDIT.EXE' -ExeArgs ("/store $($systemDrive)\boot\bcd", "/set `{default`} osdevice locate")
                    }
                }

                Write-Log 'Drive is bootable. Cleaning up...'
            }
            else {
                Write-Log 'Image applied. Not bootable.'
            }

            # Remove system partition access path, if necessary
            if ($DiskLayout -eq 'UEFI') {
                $systemPartition | Remove-PartitionAccessPath -AccessPath $systemPartition.AccessPaths[0]
            }

            if ($hyperVEnabled) {
                Write-Log "Dismounting $VHDFormat..."
                Dismount-VHD -Path $VHDPath
            }
            else {
                Write-Log "Closing $VHDFormat..."
                Dismount-DiskImage -ImagePath $VHDPath
            }

            $vhdFinalPath = Join-Path (Split-Path $VHDPath -Parent) $vhdFinalName
            Write-Log "$VHDFormat final path is : $vhdFinalPath"

            if (Test-Path $vhdFinalPath) {
                Write-Log "Deleting pre-existing $VHDFormat : $(Split-Path $vhdFinalPath -Leaf)..."
                Remove-Item -Path $vhdFinalPath -Force
            }

            Write-Log "Renaming $VHDFormat at $VHDPath to $vhdFinalName"
            Rename-Item -Path (Resolve-Path $VHDPath).Path -NewName $vhdFinalName -Force
            $vhd += Get-DiskImage -ImagePath $vhdFinalPath

            $vhdFinalName = $null
        }
        catch {
            Write-Error $_
            Write-Log "Log folder is $logDir"
        }
        finally {
            # If VHD is mounted, unmount it
            if (Test-Path $VHDPath) {
                if ($hyperVEnabled) {
                    if ((Get-VHD -Path $VHDPath).Attached) {
                        Dismount-VHD -Path $VHDPath
                    }
                }
                else {
                    Dismount-DiskImage -ImagePath $VHDPath
                }
            }

            if ($null -ne $openIso) {
                Write-Log 'Closing ISO...'
                Dismount-DiskImage $isoFinalPath
            }

            if (-not $CacheSrc) {
                if ($tempSource -and (Test-Path $tempSource)) {
                    Remove-Item -Path $tempSource -Force
                }
            }

            Write-Log 'Done.'
        }
    }

    End {
        if ($Passthru) {
            return $vhd
        }
    }
}


function New-VHDXFromWinImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImgDir,
        [Parameter(Mandatory = $true)]
        [string]$WinEdition,
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,
        [string]$VHDXPath,
        [Parameter(Mandatory = $true)]
        [uint64]$VMVHDXSizeInBytes,
        [Parameter(Mandatory = $true)]
        [string]$AdminPwd,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Server2019Datacenter', 'Server2019Standard', 'Server2016Datacenter', 'Server2016Standard', 'Windows10Enterprise', 'Windows10Professional', 'Windows81Professional')]
        [string]$Version,
        [string]$Locale = 'en-US',
        [string]$AddVirtioDrivers,
        [ValidateNotNullOrEmpty()]
        [ValidateSet('BIOS', 'UEFI', 'WindowsToGo')]
        [string]$DiskLayout = 'UEFI'
    )

    $ErrorActionPreference = 'Stop'

    if (-not $VHDXPath) {
        # https://stackoverflow.com/a/3040982
        $VHDXPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(".\$($ComputerName).vhdx")
    }

    # Source: https://docs.microsoft.com/en-us/windows-server/get-started/kmsclientkeys
    $key = @{
        'Server2019Datacenter'     = 'WMDGN-G9PQG-XVVXX-R3X43-63DFG'
        'Server2019Standard'       = 'N69G4-B89J2-4G8F4-WWYCC-J464C'
        'Server2016Datacenter'     = 'CB7KF-BWN84-R7R2Y-793K2-8XDDG'
        'Server2016Standard'       = 'WC2BQ-8NRM3-FDDYY-2BFGV-KHKQY'
        'Windows10Enterprise'      = 'NPPR9-FWDCX-D2C8J-H872K-2YT43'
        'Windows11Enterprise'      = 'NPPR9-FWDCX-D2C8J-H872K-2YT43'
        'Windows10Professional'    = 'W269N-WFGWX-YVC9B-4J6C9-T83GX'
        'Windows11Professional'    = 'W269N-WFGWX-YVC9B-4J6C9-T83GX'
        'Windows81Professional'    = 'GCRJD-8NW9H-F2CDX-CCM8D-9D6T9'
    }[$Version]

    # Create unattend.xml
    $unattendPath = $(New-WinUnattendFile -AdminPwd $AdminPwd -WinVersionKey $key -VMName $ComputerName -Locale $Locale)

    # Create VHDX from ISO image
    Write-Log "Creating VHDX from image from $unattendPath"
    Convert-WinImage -IsoPath $ImgDir -WinEdition $WinEdition -VHDPath $vhdxPath -SizeBytes $VMVHDXSizeInBytes -DiskLayout $DiskLayout -UnattendDir $unattendPath

    if ($AddVirtioDrivers) {
        Write-Log "Adding Virtio Drivers from $AddVirtioDrivers"
        Add-VirtioDrivers -VirtioIsoPath $AddVirtioDrivers -ImagePath $VHDXPath
    }

    return $VHDXPath
}

function New-VMFromWinImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImgDir,
        [Parameter(Mandatory = $true)]
        [string]$WinEdition,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Server2019Datacenter', 'Server2019Standard', 'Server2016Datacenter', 'Server2016Standard', 'Windows10Enterprise', 'Windows10Professional', 'Windows81Professional')]
        [string]$Version,
        [Parameter(Mandatory = $true)]
        [int64]$VMMemoryInBytes,
        [switch]$EnableDynamicMemory,
        [int64]$VMProcessorCount = 2,
        [Parameter(Mandatory = $true)]
        [uint64]$VMVHDXSizeInBytes,
        [Parameter(Mandatory = $true)]
        [string]$AdminPwd,
        [string]$VMMacAddress,
        [string]$AddVirtioDrivers,
        [string]$VMSwitchName = 'VMSwitch',
        [string]$Locale = 'en-US',
        [ValidateRange(1, 2)]
        [int16]$Generation = 2
    )

    $ErrorActionPreference = 'Stop'

    # Requires administrative privileges for below operations (Get-CimInstance)
    #Get Hyper-V Service Settings
    $hyperVMSettings = Get-CimInstance -namespace root\virtualization\v2 Msvm_VirtualSystemManagementServiceSettingData

    $vhdxPath = Join-Path $hyperVMSettings.DefaultVirtualHardDiskPath "$Name.vhdx"

    # Create VHDX from ISO image
    $disklayout = 'UEFI'
    if ( $Generation -eq 1 ) {
        $disklayout = 'BIOS'
        $vhdxPath = Join-Path $hyperVMSettings.DefaultVirtualHardDiskPath "$Name.vhd"
    }

    Write-Log "Using generation $Generation with disk layout $disklayout"
    New-VHDXFromWinImage `
        -ImgDir $ImgDir `
        -WinEdition $WinEdition `
        -ComputerName $Name `
        -VMVHDXSizeInBytes $VMVHDXSizeInBytes `
        -VHDXPath $vhdxPath `
        -AdminPwd $AdminPwd `
        -Version $Version `
        -Locale $Locale `
        -AddVirtioDrivers $AddVirtioDrivers `
        -DiskLayout $disklayout

    Write-Log "Creating VM in Hyper-V: $Name from VHDPath: $vhdxPath and attaching to switch: $VMSwitchName"
    $virtualMachine = New-VM -Name $Name -Generation $Generation -MemoryStartupBytes $VMMemoryInBytes -VHDPath $vhdxPath -SwitchName $VMSwitchName

    $virtualMachine | Set-VMProcessor -Count $VMProcessorCount
    $virtualMachine | Set-VMMemory -DynamicMemoryEnabled:$EnableDynamicMemory.IsPresent

    $virtualMachine | Get-VMIntegrationService | Where-Object { $_ -is [Microsoft.HyperV.PowerShell.GuestServiceInterfaceComponent] } | Enable-VMIntegrationService -Passthru

    if ($VMMacAddress) {
        $virtualMachine | Set-VMNetworkAdapter -StaticMacAddress ($VMMacAddress -replace ':', '')
    }

    $command = Get-Command Set-VM
    if ($command.Parameters.AutomaticCheckpointsEnabled) {
        # We need to disable automatic checkpoints
        $virtualMachine | Set-VM -AutomaticCheckpointsEnabled $false
    }

    #Start VM and wait for heartbeat
    $virtualMachine | Start-VM

    Write-Log 'Waiting for VM Heartbeat...'
    Wait-VM -Name $Name -For Heartbeat

    Write-Log 'All done in Creation of VM from Windows Image!'
}

function New-VMSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VMName,
        [Parameter(Mandatory = $true)]
        [string]$AdminPwd,
        [Parameter()]
        [string]$DomainName,
        [Parameter(Mandatory = $false)]
        [int]$TimeoutInSeconds = 1800,
        [Parameter(Mandatory = $false)]
        [switch]$NoLog = $false
    )

    if ($DomainName) {
        $userName = "$DomainName\administrator"
    }
    else {
        $userName = 'administrator'
    }

    $pass = ConvertTo-SecureString $AdminPwd -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($userName, $pass)
    $secondsIncrement = 5
    $elapsedSeconds = 0

    if ($NoLog -ne $true) {
        Write-Log "Waiting for connection with VM: '$VMName' (timeout: $($TimeoutInSeconds)s) ..."
    }

    do {
        $result = New-PSSession -VMName $VMName -Credential $cred -ErrorAction SilentlyContinue

        if (-not $result) {
            Start-Sleep -Seconds $secondsIncrement
            $elapsedSeconds += $secondsIncrement

            if ($NoLog -ne $true) {
                Write-Log "$($elapsedSeconds)s.. " -Progress
            }
        }
    } while (-not $result -and $elapsedSeconds -lt $TimeoutInSeconds)

    if ($elapsedSeconds -gt 0 -and $NoLog -ne $true) {
        Write-Log '.'
    }

    return $result

}

<#
.SYNOPSIS
    Opens a remote session to the specified VM.
.DESCRIPTION
    Opens a remote session to the specified VM. Throws on error.
.EXAMPLE
    $session = Open-RemoteSession -VmName 'MyVm' -VmPwd 'my secret password'
.PARAMETER VmName
    Name of the VM to connect to
.PARAMETER VmPwd
    Password of the VM user (user 'administrator' is currently hard-coded)
.PARAMETER TimeoutInSeconds
    Connection timeout
.PARAMETER DoNotThrowOnTimeout
    Writes an error to error output instead of throwing an exception
.PARAMETER NoLog
    Suppresses any output if set
.OUTPUTS
    The session object
.NOTES
    This method will throw an error, if the connection could not be established within a certain amount of time.
#>
function Open-RemoteSession {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $VmName = $(throw 'Please provide the name of the VM.'),
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $VmPwd = $(throw 'Please provide the VM user password.'),
        [Parameter(Mandatory = $false)]
        [int]$TimeoutInSeconds = 1800,
        [Parameter(Mandatory = $false)]
        [switch]$DoNotThrowOnTimeout = $false,
        [Parameter(Mandatory = $false)]
        [switch]$NoLog = $false
    )

    if ($NoLog -ne $true) {
        Write-Log "Connecting to VM '$VmName' ..."
    }

    $session = New-VMSession -VMName $VmName -AdminPwd $VmPwd -TimeoutInSeconds $TimeoutInSeconds -NoLog:$NoLog

    if (! $session ) {
        $errorMessage = "No session to VM '$VmName' possible."

        if ($DoNotThrowOnTimeout -eq $true -and $NoLog -ne $true) {
            Write-Error $errorMessage
        }
        else { throw $errorMessage }
    }

    if ($NoLog -ne $true) {
        Write-Log "Connected to VM '$VmName'."
    }

    return $session
}

function Open-RemoteSessionViaSSHKey {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Hostname = $(throw 'Please provide the hostname.'),
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $KeyFilePath = $(throw 'Please provide the path of ssh key.'),
        [Parameter(Mandatory = $false)]
        [int]$TimeoutInSeconds = 1800,
        [Parameter(Mandatory = $false)]
        [switch]$DoNotThrowOnTimeout = $false,
        [Parameter(Mandatory = $false)]
        [switch]$NoLog = $false
    )

    if ($PSVersionTable.PSVersion.Major -le 5) {
        throw 'Remote session via ssh key pair is only available in Powershell version > 5.1'
    }

    if ($NoLog -ne $true) {
        Write-Log "Connecting to '$Hostname' ..."
    }

    $session = New-VMSessionViaSSHKey -Hostname $Hostname -KeyFilePath $KeyFilePath -TimeoutInSeconds $TimeoutInSeconds -NoLog:$NoLog

    if (! $session ) {
        $errorMessage = "No session to '$Hostname' possible."

        if ($DoNotThrowOnTimeout -eq $true -and $NoLog -ne $true) {
            Write-Error $errorMessage
        }
        else { throw $errorMessage }
    }

    if ($NoLog -ne $true) {
        Write-Log "Connected to '$Hostname'."
    }

    return $session
}

function New-VMSessionViaSSHKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Hostname,
        [Parameter(Mandatory = $true)]
        [string]$KeyFilePath,
        [Parameter(Mandatory = $false)]
        [int]$TimeoutInSeconds = 1800,
        [Parameter(Mandatory = $false)]
        [switch]$NoLog = $false
    )

    $secondsIncrement = 5
    $elapsedSeconds = 0

    if ($NoLog -ne $true) {
        Write-Log "Waiting for connection with Hostname: '$Hostname' (timeout: $($TimeoutInSeconds)s) ..."
    }

    do {
        $result = New-PSSession -Hostname $Hostname -KeyFilePath $KeyFilePath -ErrorAction SilentlyContinue

        if (-not $result) {
            Start-Sleep -Seconds $secondsIncrement
            $elapsedSeconds += $secondsIncrement

            if ($NoLog -ne $true) {
                Write-Log "$($elapsedSeconds)s..<<<"
            }
        }
    } while (-not $result -and $elapsedSeconds -lt $TimeoutInSeconds)

    if ($elapsedSeconds -gt 0 -and $NoLog -ne $true) {
        Write-Log '.'
    }

    return $result
}

function Set-VmIPAddress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession[]]$PSSession,

        [Parameter(Mandatory = $false)]
        [string[]]$DnsAddr = @('8.8.8.8', '8.8.4.4'),

        [Parameter(Mandatory = $true)]
        [string]$IPAddr,

        [Parameter(Mandatory = $true)]
        [byte]$MaskPrefixLength,

        [Parameter(Mandatory = $true)]
        [string]$DefaultGatewayIpAddr
    )

    $ErrorActionPreference = 'Stop'

    Invoke-Command -Session $PSSession {
        Remove-NetRoute -NextHop $using:DefaultGatewayIpAddr -Confirm:$false -ErrorAction SilentlyContinue
        $network = 'Ethernet'
        $neta = Get-NetAdapter $network       # Use the exact adapter name for multi-adapter VMs

        Write-Output 'Remove old ip address'
        $neta | Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false

        # New-NetIPAddress may fail for certain scenarios (e.g. PrefixLength = 32). Using netsh instead.
        Write-Output 'Set new ip address'
        $mask = [IPAddress](([UInt32]::MaxValue) -shl (32 - $using:MaskPrefixLength) -shr (32 - $using:MaskPrefixLength))
        netsh interface ipv4 set address name="$($neta.InterfaceAlias)" static $using:IPAddr $mask.IPAddressToString $using:DefaultGatewayIpAddr

        Write-Output 'Disable DHCP'
        $neta | Set-NetIPInterface -Dhcp Disabled

        Write-Output 'Set DNS servers'
        $neta | Set-DnsClientServerAddress -Addresses $using:DnsAddr
    }

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
    $vmPwd = Get-DefaultTempPwd

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

    $kubePath = Get-KubePath

    $currentGitUserName = git config --get user.name
    $currentGitUserEmail = git config --get user.email

    Write-Log 'Copy Source from Host to VM node'
    Get-ChildItem $kubePath -Recurse -File | ForEach-Object { Write-log $_.FullName.Replace($kubePath, "c:\k"); Copy-VMFile $Name -SourcePath $_.FullName -DestinationPath $_.FullName.Replace($kubePath, "c:\k") -CreateFullPath -FileSource Host }

    Invoke-Command -Session $session2 -ErrorAction SilentlyContinue {
        Set-Location $env:SystemDrive\k

        Write-Output "Initialize respository under $env:SystemDrive\k"
        &'C:\Program Files\Git\cmd\git.exe' init
        if ($using:Proxy) {
            Write-Output 'Configuring Proxy for git'
            &'C:\Program Files\Git\cmd\git.exe' config --global http.proxy $using:Proxy
        }

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

        Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.node.module\windowsnode\system\system.module.psm1
        Stop-InstallationIfRequiredCurlVersionNotInstalled
        
        Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1
        Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.node.module\k2s.node.module.psm1
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
        [parameter(Mandatory = $true, HelpMessage = 'Windows VM Name to use')]
        [string] $VMName,
        [parameter(Mandatory = $false, HelpMessage = 'IP address of the VM')]
        [string] $IpAddress,
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

    Set-ConfigVMNodeHostname $VMName

    $vmPwd = Get-DefaultTempPwd
    $session = Open-RemoteSession -VmName $VMName -VmPwd $vmPwd

    Initialize-SSHConnectionToWinVM $session $IpAddress

    Initialize-PhysicalNetworkAdapterOnVM $session

    Repair-WindowsAutoConfigOnVM $session

    Restart-VirtualMachine $VMName $vmPwd
    $session = Open-RemoteSession -VmName $VMName -VmPwd $vmPwd

    # INITIALIZE WINDOWS NODE
    Invoke-Command -Session $session {
        Set-Location "$env:SystemDrive\k"
        Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

        Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1
        Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.node.module\k2s.node.module.psm1
        Initialize-Logging -Nested:$true

        # ForceOnelineInstallation should be always as host windows version (pause) is not compatible with vm node version, we need to download appropriate version for node.
        Initialize-WinNode -KubernetesVersion $using:KubernetesVersion `
            -HostGW:$using:HostGW `
            -HostVM:$using:HostVM `
            -Proxy:"$using:Proxy" `
            -DeleteFilesForOfflineInstallation $using:DeleteFilesForOfflineInstallation `
            -ForceOnlineInstallation $true
    }

    # Establish communication
    Invoke-Command -Session $session {
        Set-Location "$env:SystemDrive\k"
        Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

        Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1
        Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.node.module\k2s.node.module.psm1
        Initialize-Logging -Nested:$true
        Wait-ForSSHConnectionToLinuxVMViaSshKey -Nested:$true
    }

    Write-Log 'Windows VM worker node initialized.'
}

function Initialize-SSHConnectionToWinVM($session, $IpAddress) {
    # remove previous VM key from known hosts
    $sshConfigDir = Get-SshConfigDir
    $file = $sshConfigDir + '\known_hosts'
    if (Test-Path $file) {
        Write-Log 'Remove previous VM key from known_hosts file'
        $ErrorActionPreference = 'Continue'
        ssh-keygen.exe -R $IpAddress 2>&1 | % { "$_" }
        $ErrorActionPreference = 'Stop'
    }

    $windowsVMKey = Get-DefaultWinVMKey
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
        Set-Location "$env:SystemDrive\k"
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

function Remove-VMSshKey() {
    Write-Log 'Remove vm node worker ssh keys'
    $rootConfig = Get-RootConfigk2s
    $multivmRootConfig = $rootConfig.psobject.properties['multivm'].value
    $multiVMWinNodeIP = $multivmRootConfig.psobject.properties['multiVMK8sWindowsVMIP'].value

    $sshConfigDir = Get-SshConfigDir

    ssh-keygen.exe -R $multiVMWinNodeIP 2>&1 | % { "$_" }
    Remove-Item -Path ($sshConfigDir + '\kubemaster') -Force -Recurse -ErrorAction SilentlyContinue
}

function Initialize-PhysicalNetworkAdapterOnVM ($session) {
    Write-Log 'Checking physical network adapter on Windows node ...'

    Invoke-Command -Session $session {
        Set-Location "$env:SystemDrive\k"
        Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

        Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1
        Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.node.module\k2s.node.module.psm1
        Initialize-Logging -Nested:$true

        # Install loopback adapter for l2bridge
        New-DefaultLoopbackAdater
    }
}

function Repair-WindowsAutoConfigOnVM($session) {
    Invoke-Command -Session $session {
        Set-Location "$env:SystemDrive\k"
        Set-ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue

        Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1
        Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.node.module\k2s.node.module.psm1
        Initialize-Logging -Nested:$true

        # TODO Convert as function? or move to helpers
        & "$env:SystemDrive\k\smallsetup\FixAutoconfiguration.ps1"
    }
}

function Enable-SSHRemotingViaSSHKeyToWinNode ($session, $Proxy) {
    Invoke-Command -Session $session {
        Set-Location "$env:SystemDrive\k"
        Set-ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue

        if ($using:Proxy -ne "") {
            pwsh -Command "`$ENV:HTTPS_PROXY='$using:Proxy';Install-Module -Name Microsoft.PowerShell.RemotingTools -Force -Confirm:`$false"
        } else {
            pwsh -Command "Install-Module -Name Microsoft.PowerShell.RemotingTools -Force -Confirm:`$false"
        }

        pwsh -Command "Get-InstalledModule"
        pwsh -Command "Enable-SSHRemoting -Force"

        Restart-Service sshd
    }
}

function Disable-PasswordAuthenticationToWinNode () {
    $vmSessionKey = Open-DefaultWinVMRemoteSessionViaSSHKey

    Invoke-Command -Session $vmSessionKey {
        Set-Location "$env:SystemDrive\k"
        Set-ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue

        # Change password on next login
        cmd.exe /c "wmic UserAccount where name='Administrator' set Passwordexpires=true"
        cmd.exe /c "net user Administrator /logonpasswordchg:yes"

        # Disable password authentication over ssh
        Add-Content "C:\ProgramData\ssh\sshd_config" "`nPasswordAuthentication no"
        Restart-Service sshd

        # Disable WinRM
        netsh advfirewall firewall set rule name="Windows Remote Management (HTTP-In)" new enable=yes action=block
        netsh advfirewall firewall set rule group="Windows Remote Management" new enable=yes
        $winrmService = Get-Service -Name WinRM
        if ($winrmService.Status -eq "Running"){
            Disable-PSRemoting -Force
        }
        Stop-Service winrm
        Set-Service -Name winrm -StartupType Disabled

        # Disable Powershell Direct
        Stop-Service vmicvmsession
        Set-Service -Name vmicvmsession -StartupType Disabled
    }
}

function Get-DefaultWinVMName {
    $rootConfig = Get-RootConfigk2s
    $multivmRootConfig = $rootConfig.psobject.properties['multivm'].value
    $multiVMWinNodeIP = $multivmRootConfig.psobject.properties['multiVMK8sWindowsVMIP'].value
    return "administrator@$multiVMWinNodeIP"
}

function Get-DefaultWinVMKey {
    $sshConfigDir = Get-SshConfigDir
    $windowsVMKey = $sshConfigDir + "\windowsvm\$(Get-SSHKeyFileName)"

    return $windowsVMKey
}

function Open-DefaultWinVMRemoteSessionViaSSHKey {
    $adminWinNode = Get-DefaultWinVMName
    $windowsVMKey = Get-DefaultWinVMKey

    $vmSessionKey = Open-RemoteSessionViaSSHKey -Hostname $adminWinNode -KeyFilePath $windowsVMKey

    return $vmSessionKey
}

<#
.SYNOPSIS
    Waits until a command can be executet via SSH on a Windows machine.
.DESCRIPTION
    Waits until a command can be executet via SSH on a Windows machine. Convenience wrapper around Wait-ForSshPossible.
.EXAMPLE
    Wait-ForSSHConnectionToWindowsVMViaSshKey
#>
function Wait-ForSSHConnectionToWindowsVMViaSshKey() {
    $adminWinNode = Get-DefaultWinVMName
    $windowsVMKey = Get-DefaultWinVMKey
    $multiVMWindowsVMName = Get-ConfigVMNodeHostname
    Wait-ForSshPossible -User $adminWinNode -SshKey $windowsVMKey -SshTestCommand 'whoami' -ExpectedSshTestCommandResult "$multiVMWindowsVMName\administrator" -StrictEqualityCheck
}

function Set-VMVFPRules {
    $kubeBinPath = Get-KubeBinPath
    $file = "$kubeBinPath\cni\vfprules.json"
    Remove-Item -Path $file -Force -ErrorAction SilentlyContinue

    $smallsetup = Get-RootConfigk2s
    $smallsetup.psobject.properties['vfprules-multivm'].value | ConvertTo-Json | Out-File "$kubeBinPath\cni\vfprules.json" -Encoding ascii
    Write-Log "Created new version of $file for vm node"
}

function Invoke-CmdOnVMWorkerNodeViaSSH(
    [Parameter(Mandatory = $false)]
    $CmdToExecute)
{
    $adminWinNode = Get-DefaultWinVMName
    $windowsVMKey = Get-DefaultWinVMKey

    ssh.exe -n -o StrictHostKeyChecking=no -i $windowsVMKey $adminWinNode $CmdToExecute 2> $null
}

Export-ModuleMember Get-IsVmOperating,
Start-VirtualMachine, Stop-VirtualMachine,
Restart-VirtualMachine, Remove-VirtualMachine,
Remove-VMSnapshots, Wait-ForDesiredVMState,
New-VMFromWinImage, Open-RemoteSession,
New-VMSession, Set-VmIPAddress,
Open-RemoteSessionViaSSHKey, New-VMSessionViaSSHKey,
Initialize-WinVM, Initialize-WinVMNode,
Wait-ForSSHConnectionToWindowsVMViaSshKey,Get-DefaultWinVMKey,
Open-DefaultWinVMRemoteSessionViaSSHKey, Enable-SSHRemotingViaSSHKeyToWinNode,
Disable-PasswordAuthenticationToWinNode, Get-DefaultWinVMName,
Set-VMVFPRules, Remove-VMSshKey,
Invoke-CmdOnVMWorkerNodeViaSSH