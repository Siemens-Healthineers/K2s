# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

# load global settings
&$PSScriptRoot\GlobalVariables.ps1

$logModule = "$PSScriptRoot\..\ps-modules\log\log.module.psm1"
#Import logging module for backward compatibility, should be removed once the migration is complete
Import-Module $logModule

# GlobalFunctions.ps1
#   reuse methods over multiple scripts

<#
.Description
ExecCmdMaster executes cmd on master.
#>
function ExecCmdMaster(
    [Parameter(Mandatory = $false)]
    $CmdToExecute,
    [Parameter(Mandatory = $false)]
    [switch]$IgnoreErrors = $false,
    [Parameter(Mandatory = $false)]
    [switch]$UsePwd = $false,
    [Parameter(Mandatory = $false)]
    [uint16]$Retries = 0,
    [Parameter(Mandatory = $false)]
    [uint16]$Timeout = 2,
    [Parameter(Mandatory = $false)]
    [switch]$NoLog = $false,
    [Parameter(Mandatory = $false)]
    [string]$RemoteUser = $global:Remote_Master,
    [Parameter(Mandatory = $false)]
    [string]$RemoteUserPwd = $global:VMPwd,
    [Parameter(HelpMessage = 'When executing ssh.exe in nested environment[host=>VM=>VM], -n flag should not be used.')]
    [switch]$Nested = $false,
    [Parameter(Mandatory = $false, HelpMessage = 'text that gets logged instead of the original command that contains potentially sensitive data')]
    [string]$CmdLogReplacement,
    [Parameter(Mandatory = $false, HelpMessage = 'repair comd for the case first run did not work out')]
    [string]$RepairCmd = $null) {
    $cmdLogText = $CmdToExecute
    if ($CmdLogReplacement) {
        $cmdLogText = $CmdLogReplacement
    }

    if (!$NoLog) {
        Write-Log "cmd: $cmdLogText, retries: $Retries, timeout: $Timeout sec, ignore err: $IgnoreErrors, nested: $nested"
    }
    $Stoploop = $false
    [uint16]$Retrycount = 1
    do {
        try {
            if ($UsePwd) {
                &"$global:SshExe" -ssh -4 $RemoteUser -pw $RemoteUserPwd -no-antispoof $CmdToExecute 2>&1 | ForEach-Object { Write-Log $_ -Console -Raw }
            }
            else {
                if ($Nested) {
                    ssh.exe -o StrictHostKeyChecking=no -i $global:LinuxVMKey $RemoteUser $CmdToExecute 2>&1 | ForEach-Object { Write-Log $_ -Console -Raw }
                }
                else {
                    ssh.exe -n -o StrictHostKeyChecking=no -i $global:LinuxVMKey $RemoteUser $CmdToExecute 2>&1 | ForEach-Object { Write-Log $_ -Console -Raw }
                }
            }
            if ($LASTEXITCODE -ne 0 -and !$IgnoreErrors) { throw "Error occurred while executing command '$cmdLogText' (exit code: '$LASTEXITCODE')" }
            $Stoploop = $true
        }
        catch {
            Write-Log $_
            if ($Retrycount -gt $Retries) {
                $Stoploop = $true
            }
            else {
                Write-Log "cmd: $cmdLogText will be retried.."
                # try to repair the cmd
                if( ($null -ne $RepairCmd) -and !$UsePwd -and !$IgnoreErrors) {
                    Write-Log "Executing repair cmd: $RepairCmd"
                    if ($Nested) {
                        ssh.exe -o StrictHostKeyChecking=no -i $global:LinuxVMKey $RemoteUser $RepairCmd 2>&1 | ForEach-Object { Write-Log $_ -Console -Raw }
                    }
                    else {
                        ssh.exe -n -o StrictHostKeyChecking=no -i $global:LinuxVMKey $RemoteUser $RepairCmd 2>&1 | ForEach-Object { Write-Log $_ -Console -Raw }
                    }
                }
                Start-Sleep -Seconds $Timeout
                $Retrycount = $Retrycount + 1
            }
        }
    }
    While ($Stoploop -eq $false)
}

<#
.Description
Copy-FromToMaster copies files to master.
#>
function Copy-FromToMaster($Source, $Target,
    [Parameter(Mandatory = $false)]
    [switch]$IgnoreErrors = $false,
    [Parameter(Mandatory = $false)]
    [switch]$UsePwd = $false,
    [Parameter(Mandatory = $false)]
    [string]$RemoteUserPwd = $global:VMPwd) {
    Write-Log "copy: $Source to: $Target IgnoreErrors: $IgnoreErrors"
    $error.Clear()
    if ($UsePwd) {
        echo yes | &"$global:ScpExe" -ssh -4 -q -r -pw $RemoteUserPwd "$Source" "$Target" 2>&1 | ForEach-Object { "$_" }
    }
    else {
        scp.exe -o StrictHostKeyChecking=no -r -i $global:LinuxVMKey "$Source" "$Target" 2>&1 | ForEach-Object { "$_" }
    }

    if ($error.count -gt 0 -and !$IgnoreErrors) { throw "Executing $CmdToExecute failed! " + $error }
}

<#
.SYNOPSIS
    Waits until a command can be executet via SSH on a remote machine.
.DESCRIPTION
    Waits until a command can be executet via SSH on a remote machine. Aborts the operation if a certain number of retries failed.
.PARAMETER RemoteUser
    The user and IP of the remote machine, e.g. admin@192.168.0.11
.PARAMETER RemotePwd
    The password for the remote user
.PARAMETER SshTestCommand
    The SSH test command to execute on the remote machine, e.g. 'whoami'
.PARAMETER ExpectedSshTestCommandResult
    The expected SSH test command result. DEFAULT: regex expression; with StrictEqualityCheck = $true: e.g. for command 'whoami' ==> 'my-machine\admin'
.PARAMETER StrictEqualityCheck
    If set, the SSH test command result will be checked with strict equality comparer (i.e. '-eq') instead of a regex expression match
.EXAMPLE
    Wait-ForSshPossible -RemoteUser 'admin@192.168.0.11' -RemotePwd 'my-secret' -SshTestCommand 'which curl' -ExpectedSshTestCommandResult '/bin/curl'
    ==> result will match the regex expression
.EXAMPLE
    Wait-ForSshPossible -RemoteUser 'admin@192.168.0.11' -RemotePwd 'my-secret' -SshTestCommand 'whoami' -ExpectedSshTestCommandResult 'my-machine\admin' -StrictEqualityCheck
    ==> result will be checked for strict equality, i.e. <result> -eq 'my-machine\admin'
#>
function Wait-ForSshPossible {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $RemoteUser = $(throw 'Please specify the user and IP of the remote machine, e.g. admin@192.168.0.11'),
        [Parameter()]
        [string]$SshKey = '',
        [Parameter()]
        [string]$RemotePwd = '',
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$SshTestCommand = $(throw 'Please specify the SSH test command to execute on the remote machine.'),
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$ExpectedSshTestCommandResult = $(throw 'Please specify the expected SSH test command result.'),
        [Parameter(HelpMessage = 'Check the expected and actual result for strict equality; otherwise, a regex match will be conducted.')]
        [switch]$StrictEqualityCheck = $false,
        [Parameter(HelpMessage = 'When executing ssh.exe in nested environment[host=>VM=>VM], -n flag should not be used.')]
        [switch]$Nested = $false
    )
    $iteration = 0
    Write-Log "Performing SSH login into VM with $($RemoteUser)..."
    while ($true) {
        $iteration++
        $result = ''

        if ($SshKey -ne '') {
            if ($Nested) {
                $result = ssh.exe -o StrictHostKeyChecking=no -i $SshKey $RemoteUser "$($SshTestCommand)" 2>&1
            }
            else {
                $result = ssh.exe -n -o StrictHostKeyChecking=no -i $SshKey $RemoteUser "$($SshTestCommand)" 2>&1
            }
        }
        else {
            $result = $(echo yes | &"$global:SshExe" -ssh -4 $RemoteUser -pw $RemotePwd -no-antispoof "$($SshTestCommand)" 2>&1)
        }

        if ($StrictEqualityCheck -eq $true) {
            if ($result -eq $ExpectedSshTestCommandResult) {
                break
            }
        }
        else {
            if ($result -match $ExpectedSshTestCommandResult) {
                break
            }
        }

        if ($iteration -eq 25) {
            Write-Log "SSH login into VM with $($RemoteUser) still not available, aborting..."
            throw "Unable to login into VM with $($RemoteUser)"
        }
        if ($iteration -ge 3 ) {
            Write-Log "SSH login into VM with $($RemoteUser) not yet possible, waiting for it..."
        }
        Start-Sleep 4
    }
    if ($iteration -eq 1) {
        Write-Log "SSH login into VM with $($RemoteUser) possible, no waiting needed."
    }
    else {
        Write-Log "SSH login into VM with $($RemoteUser) now possible."
    }
}

<#
.SYNOPSIS
    Establishes first time connection with VM by accepting the key and retries until a command can be executet via SSH on a Linux machine.
.DESCRIPTION
    Waits until Initial connection command can be executet via SSH on a Linux machine.
.EXAMPLE
    Wait-ForSSHConnectionToLinuxVMViaPwd
#>
function Wait-ForSSHConnectionToLinuxVMViaPwd(
    [Parameter(Mandatory = $false)]
    [string]$RemoteUser = $global:Remote_Master,
    [Parameter(Mandatory = $false)]
    [string]$RemoteUserPwd = $global:VMPwd) {
    Write-Log "Initiating first time SSH login into VM with user $global:Remote_Master"
    Wait-ForSshPossible -RemoteUser $RemoteUser -RemotePwd $RemoteUserPwd -SshTestCommand 'which curl' -ExpectedSshTestCommandResult '/bin/curl'
}


<#
.SYNOPSIS
    Waits until a command can be executet via SSH on a Linux machine.
.DESCRIPTION
    Waits until a command can be executet via SSH on a Linux machine. Convenience wrapper around Wait-ForSshPossible.
.EXAMPLE
    Wait-ForSSHConnectionToLinuxVMViaSshKey
#>
function Wait-ForSSHConnectionToLinuxVMViaSshKey($Nested = $false) {
    Wait-ForSshPossible -RemoteUser $global:Remote_Master -SshKey $global:LinuxVMKey -SshTestCommand 'which curl' -ExpectedSshTestCommandResult '/bin/curl' -Nested:$Nested
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
    Wait-ForSshPossible -RemoteUser $global:Admin_WinNode -SshKey $global:WindowsVMKey -SshTestCommand 'whoami' -ExpectedSshTestCommandResult "$global:MultiVMWindowsVMName\administrator" -StrictEqualityCheck
}

<#
.Description
SaveCloudInitFiles save cloud init files to master VM.
#>
function SaveCloudInitFiles () {
    $target = "$($global:SystemDriveLetter):\var\log\cloud-init"
    $source = "$global:Remote_Master" + ':/var/log/cloud-init*'
    Remove-Item -Path $target -Force -Recurse -ErrorAction SilentlyContinue | Out-Null
    mkdir $target -ErrorAction SilentlyContinue | Out-Null
    Write-Log "copy $source to $target"
    Copy-FromToMaster $source $target
}

<#
.Description
DownloadFile download file from internet.
#>
function DownloadFile($destination, $source, $forceDownload,
    [parameter(Mandatory = $false)]
    [string] $ProxyToUse = $Proxy) {
    if ((Test-Path $destination) -and (!$forceDownload)) {
        Write-Log "using existing $destination"
        return
    }
    if ( $ProxyToUse -ne '' ) {
        Write-Log "Downloading '$source' to '$destination' with proxy: $ProxyToUse"
        curl.exe --retry 5 --connect-timeout 60 --retry-all-errors --retry-delay 60 --silent --disable --fail -Lo $destination $source --proxy $ProxyToUse --ssl-no-revoke -k #ignore server certificate error for cloudbase.it
    }
    else {
        Write-Log "Downloading '$source' to '$destination' (no proxy)"
        curl.exe --retry 5 --connect-timeout 60 --retry-all-errors --retry-delay 60 --silent --disable --fail -Lo $destination $source --ssl-no-revoke --noproxy '*'
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
CopyDotFile copy dot files for bash processing to master VM.
#>
function CopyDotFile($SourcePath, $DotFile,
    [Parameter(Mandatory = $false)]
    [string]$RemoteUser = $global:Remote_Master,
    [Parameter(Mandatory = $false)]
    [string]$RemoteUserPwd = $global:VMPwd) {
    Write-Log "copying $SourcePath$DotFile to VM..."
    $source = "$SourcePath$DotFile"
    if (Test-Path($source)) {
        $target = "$RemoteUser" + ":$DotFile.temp"
        $userName = $RemoteUser.Substring(0, $RemoteUser.IndexOf('@'))
        Copy-FromToMaster -Source $source -Target $target -RemoteUserPwd $RemoteUserPwd -UsePwd
        ExecCmdMaster "sed 's/\r//g' $DotFile.temp > ~/$DotFile" -RemoteUser "$RemoteUser" -RemoteUserPwd "$RemoteUserPwd" -UsePwd
        ExecCmdMaster "sudo chown -R $userName ~/$DotFile" -RemoteUser "$RemoteUser" -RemoteUserPwd "$RemoteUserPwd" -UsePwd
        ExecCmdMaster "rm $DotFile.temp" -RemoteUser "$RemoteUser" -RemoteUserPwd "$RemoteUserPwd" -UsePwd
    }
}

<#
.Description
AddAptRepo add repository for apt in master VM.
#>
function AddAptRepo {
    param (
        [Parameter(Mandatory = $false)]
        [string]$RepoKeyUrl = '',
        [Parameter(Mandatory)]
        [string]$RepoDebString,
        [Parameter(Mandatory = $false)]
        [string]$ProxyApt = '',
        [Parameter(Mandatory = $false)]
        [string]$RemoteUser = $global:Remote_Master,
        [Parameter(Mandatory = $false)]
        [string]$RemoteUserPwd = $global:VMPwd
    )
    Write-Log "adding apt-repository '$RepoDebString' with proxy '$ProxyApt' from '$RepoKeyUrl'"
    if ($RepoKeyUrl -ne '') {
        if ($ProxyApt -ne '') {
            ExecCmdMaster "curl --retry 3 --retry-all-errors -s -k $RepoKeyUrl --proxy $ProxyApt | sudo apt-key add - 2>&1" -RemoteUser "$RemoteUser" -RemoteUserPwd "$RemoteUserPwd" -UsePwd
        }
        else {
            ExecCmdMaster "curl --retry 3 --retry-all-errors -fsSL $RepoKeyUrl | sudo apt-key add - 2>&1" -RemoteUser "$RemoteUser" -RemoteUserPwd "$RemoteUserPwd" -UsePwd
        }
        if ($LASTEXITCODE -ne 0) { throw "adding repo '$RepoDebString' failed. Aborting." }
    }
    ExecCmdMaster "sudo add-apt-repository '$RepoDebString' 2>&1" -RemoteUser "$RemoteUser" -RemoteUserPwd "$RemoteUserPwd" -UsePwd
    if ($LASTEXITCODE -ne 0) { throw "adding repo '$RepoDebString' failed. Aborting." }
}

<#
.Description
InstallAptPackages install apt package to master VM.
#>
function InstallAptPackages {
    param (
        [Parameter(Mandatory)]
        [string]$FriendlyName,
        [Parameter(Mandatory)]
        [string]$Packages,
        [Parameter(Mandatory = $false)]
        [string]$TestExecutable = '',
        [Parameter(Mandatory = $false)]
        [string]$RemoteUser = $global:Remote_Master,
        [Parameter(Mandatory = $false)]
        [string]$RemoteUserPwd = $global:VMPwd
    )
    Write-Log "installing needed apt packages for $FriendlyName..."
    ExecCmdMaster "sudo DEBIAN_FRONTEND=noninteractive apt-get install -qq --yes --fix-missing $Packages" -Retries 2 -Timeout 2 -RemoteUser "$RemoteUser" -RemoteUserPwd "$RemoteUserPwd" -UsePwd -RepairCmd "sudo apt --fix-broken install"

    if ($TestExecutable -ne '') {
        $exeInstalled = $(ExecCmdMaster "which $TestExecutable" -RemoteUser "$RemoteUser" -RemoteUserPwd "$RemoteUserPwd" -NoLog -UsePwd)
        if (!($exeInstalled -match "/bin/$TestExecutable")) {
            throw "'$FriendlyName' was not installed correctly"
        }
    }
}

<#
.Description
Restart-VM restarts the VM and wait till it's available.
#>
function Restart-VM($VMName) {
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

        $con = &$PSScriptRoot\vmtools\New-VMSession.ps1 -VMName $VMName -AdministratorPassword $global:VMPwd
        if ($con) {
            Write-Log "           connect succeeded to $VMName VM"
            break;
        }
    }
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

<#
.SYNOPSIS
    Creates a specified directory if not existing.
.DESCRIPTION
    Creates a specified directory if not existing.
.EXAMPLE
    New-DirectoryIfNotExisting -Path 'c:\temp-dir'
    New-DirectoryIfNotExisting 'c:\temp-dir'
    'c:\temp-dir' | New-DirectoryIfNotExisting
.PARAMETER Path
    Directory path
.NOTES
    Function supports pipelines ('Path')
#>
function New-DirectoryIfNotExisting {
    param (
        [Parameter(ValueFromPipeline)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    if (!(Test-Path $Path)) {
        Write-Log "Directory '$Path' not existing, creating it ..."

        New-Item -Path $Path -ItemType Directory | Out-Null

        Write-Log "Directory '$Path' created."
    }
    else {
        Write-Log "Directory '$Path' already existing."
    }
}

<#
.SYNOPSIS
    Writes a key-value pair to a given JSON file.
.DESCRIPTION
    Writes a key-value pair to a given JSON file.
.EXAMPLE
    Set-ConfigValue -Path "config.json" -Key 'version' -Value '123'
.PARAMETER Path
    Path to config JSON file
.PARAMETER Key
    Property key
.PARAMETER Value
    Property value
.NOTES
    Config file must contain valid JSON.
    Only top-level properties are set.
    Existing properties with the same key get overwritten.
    If the config file does not exist, it will be created.
#>
function Set-ConfigValue {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Path = $(throw 'Please provide the config file path.'),
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Key = $(throw 'Please provide the config key.'),
        [Parameter()]
        [object] $Value = $(throw 'Please provide the config value.')
    )

    if (Test-Path $Path) {
        $json = $(Get-Content $Path -Raw | ConvertFrom-Json)
    }
    else {
        Split-Path -parent $Path | New-DirectoryIfNotExisting

        $json = @{ }
    }

    $json | Add-Member -Name $Key -Value $Value -MemberType NoteProperty -Force

    $json | ConvertTo-Json -Depth 32 | Set-Content -Force $Path # default object depth appears to be 2
}

<#
.SYNOPSIS
    Retrieves the specified config value from a given JSON file.
.DESCRIPTION
    Retrieves the specified config value from a given JSON file.
.EXAMPLE
    $version = Get-ConfigValue -Path "config.json" -Key 'version'
.PARAMETER Path
    Path to config JSON file
.PARAMETER Key
    Property key
.OUTPUTS
    The property value if existing; otherwise null
.NOTES
    Config file must contain valid JSON.
    Only top-level properties are read.
    If the property exists with null value, null will be returned (same as if the property did not exist).
    If the config file does not exist, null will be returned.
#>
function Get-ConfigValue {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Path = $(throw 'Please provide the config file path.'),
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Key = $(throw 'Please provide the config key.')
    )

    if (!(Test-Path $Path)) {
        return
    }

    return $(Get-Content $Path -Raw | ConvertFrom-Json).$Key
}

<#
.SYNOPSIS
    Returns the installed K8s version if present.
.DESCRIPTION
    Returns the installed K8s version if present.
.EXAMPLE
    $version = Get-InstalledKubernetesVersion
.OUTPUTS
    The installed K8s version if present; otherwise 'unknown'
.NOTES
    Checks the local setup json file for the K8s version
#>
function Get-InstalledKubernetesVersion {
    if (!$global:SetupJsonFile -or !$global:ConfigKey_K8sVersion) {
        throw "The calling script must include the file 'GlobalVariables.ps1' first!"
    }

    $result = Get-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_K8sVersion

    if ($result) {
        return $result
    }

    return 'unknown'
}

<#
.SYNOPSIS
    Deprecaded: use K2s\lib\modules\k2s\k2s.infra.module\config\config.module.psm1::Get-ConfigSetupType instead
.DESCRIPTION
    Deprecaded: use K2s\lib\modules\k2s\k2s.infra.module\config\config.module.psm1::Get-ConfigSetupType instead
#>
function Get-Installedk2sSetupType {
    if (!$global:SetupJsonFile -or !$global:ConfigKey_SetupType) {
        throw "The calling script must include the file 'GlobalVariables.ps1' first!"
    }

    $result = Get-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_SetupType

    if ($result) {
        return $result
    }

    # if no entry exists (e.g. due to older setup), return the default (most likely the 'standard' K2s setup)
    return $global:SetupType_k2s
}

<#
.SYNOPSIS
    Returns the config entry for containerd if present.
.DESCRIPTION
    Returns the config entry for containerd if present. Otherwise FALSE.
.EXAMPLE
    $useContainerd = Get-UseContainerdFromConfig
.OUTPUTS
    The boolean containerd config entry if present; otherwise FALSE
#>
function Get-UseContainerdFromConfig {
    if (!$global:SetupJsonFile -or !$global:ConfigKey_Containerd) {
        throw "The calling script must include the file 'GlobalVariables.ps1' first!"
    }

    $result = Get-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_Containerd

    return $result -eq $true
}

<#
.SYNOPSIS
    Returns the host GW config if present.
.DESCRIPTION
    Returns the host GW config if present.
.EXAMPLE
    $isHostGw = Get-HostGwFromConfig
.OUTPUTS
    The host GW config if present; otherwise FALSE.
#>
function Get-HostGwFromConfig {
    if (!$global:SetupJsonFile -or !$global:ConfigKey_HostGw) {
        throw "The calling script must include the file 'GlobalVariables.ps1' first!"
    }

    $hostGwConfig = Get-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_HostGw

    if ([string]::IsNullOrEmpty($hostGwConfig)) {
        return $true
    }

    return $hostGwConfig -eq $true
}

function Get-WSLFromConfig {
    if (!$global:SetupJsonFile -or !$global:ConfigKey_WSL) {
        throw "The calling script must include the file 'GlobalVariables.ps1' first!"
    }

    $wslConfig = Get-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_WSL

    if ([string]::IsNullOrEmpty($wslConfig)) {
        return $false
    }

    return $wslConfig -eq $true
}

function Get-LinuxOnlyFromConfig {
    if (!$global:SetupJsonFile -or !$global:ConfigKey_LinuxOnly) {
        throw "The calling script must include the file 'GlobalVariables.ps1' first!"
    }

    $result = Get-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_LinuxOnly

    if ([string]::IsNullOrEmpty($result)) {
        return $false
    }

    return $result -eq $true
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

    if (!$global:KubernetesPath) {
        throw "The calling script must include the file 'GlobalVariables.ps1' first!"
    }

    if ($NoLog -ne $true) {
        Write-Log "Connecting to VM '$VmName' ..."
    }

    $session = &"$global:KubernetesPath\smallsetup\common\vmtools\New-VMSession.ps1" -VMName $VmName -AdministratorPassword $VmPwd -TimeoutInSeconds $TimeoutInSeconds -NoLog:$NoLog

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

    if (!$global:KubernetesPath) {
        throw "The calling script must include the file 'GlobalVariables.ps1' first!"
    }

    if ($NoLog -ne $true) {
        Write-Log "Connecting to '$Hostname' ..."
    }

    $session = &"$global:KubernetesPath\smallsetup\common\vmtools\New-VMSessionViaSSHKey.ps1" -Hostname $Hostname -KeyFilePath $KeyFilePath -TimeoutInSeconds $TimeoutInSeconds -NoLog:$NoLog

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

<#
.SYNOPSIS
    Starts a specified service and sets it to auto-start.
.DESCRIPTION
    Starts a specified service and sets it to auto-start.
.PARAMETER Name
    Name of the service
.EXAMPLE
    Start-ServiceAndSetToAutoStart -Name 'kubelet'
.NOTES
    Does nothing if the service was not found.
#>
function Start-ServiceAndSetToAutoStart {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Name = $(throw 'Please provide the name of the service.')
    )

    if (!$global:NssmInstallDirectory -or !$global:NssmInstallDirectoryLegacy) {
        throw "The calling script must include the file 'GlobalVariables.ps1' first!"
    }

    $svc = $(Get-Service -Name $Name -ErrorAction SilentlyContinue).Status

    if ($svc) {
        $nssm = "$global:NssmInstallDirectory\nssm.exe"
        if (!(Test-Path $nssm)) {
            $nssm = "$global:NssmInstallDirectoryLegacy\nssm.exe"
        }
        Write-Log ('Changing service to auto startup and starting: ' + $Name)
        &$nssm set $Name Start SERVICE_AUTO_START | Out-Null
        Start-Service $Name -WarningAction SilentlyContinue
        Write-Log "service started: $Name"
    }
}

<#
.SYNOPSIS
    Restarts a specified service if it is running
.DESCRIPTION
    Restarts a specified service if it is running.
.PARAMETER Name
    Name of the service
.EXAMPLE
    Restart-WinService -Name 'WslService'
.NOTES
    Does nothing if the service was not found.
#>
function Restart-WinService {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Name = $(throw 'Please provide the name of the windows service.')
    )

    $svc = $(Get-Service -Name $Name -ErrorAction SilentlyContinue).Status
    if ($svc) {
        Write-Log "Service status before restarting '$Name': $svc"
        Restart-Service $Name -WarningAction SilentlyContinue -Force
        $iteration = 0
        while ($true) {
            $iteration++
            $svcstatus = $(Get-Service -Name $Name -ErrorAction SilentlyContinue).Status
            if ($svcstatus -eq 'Running') {
                Write-Log "Service re-started '$Name' "
                break
            }
            if ($iteration -ge 5) {
                Write-Warning "'$Name' Service is not running !!"
                break
            }
            Write-Log "'$Name' Waiting for service status to be started: $svc"
            Start-Sleep -s 2
        }
        return
    }
    Write-Warning "Service not found: $Name"
}

<#
.SYNOPSIS
    Outputs node service status.
.DESCRIPTION
    Outputs node service status.
.PARAMETER Iteration
    Iteration no.
.EXAMPLE
    Write-NodeServiceStatus -Iteration 3
#>
function Write-NodeServiceStatus {
    param (
        [Parameter(Mandatory = $true)]
        [int] $Iteration
    )

    $prefix = "State of services (checkpoint $Iteration):"
    $stateFlanneld = $(Get-Service flanneld).Status
    $stateKubelet = $(Get-Service kubelet).Status
    $stateKubeproxy = $(Get-Service kubeproxy).Status
    if ($stateFlanneld -eq 'Running' -and $stateKubelet -eq 'Running' -and $stateKubeproxy -eq 'Running') {
        Write-Log "$prefix All running"
    }
    elseif ($stateFlanneld -eq 'Stopped' -and $stateKubelet -eq 'Stopped' -and $stateKubeproxy -eq 'Stopped') {
        Write-Log "$prefix All STOPPED"
    }
    else {
        Write-Log "$prefix"
        Write-Log "             flanneld:  $stateFlanneld"
        Write-Log "             kubelet:   $stateKubelet"
        Write-Log "             kubeproxy: $stateKubeproxy"
    }

    Write-Log '###################################################'
    Write-Log "flanneld:  $stateFlanneld"
    $adapterName = Get-L2BridgeNIC
    Get-NetIPAddress -InterfaceAlias $adapterName -ErrorAction SilentlyContinue | Out-Null
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

<#
.SYNOPSIS
    Enables missing Windows features.
.DESCRIPTION
    Enables missing Windows features if disabled.
.EXAMPLE
    Enable-MissingWindowsFeatures
.NOTES
    If any of the enabled features requires a restart, the user will be prompted to restart the computer.
#>
function Enable-MissingWindowsFeatures($wsl) {
    $global:InstallRestartRequired = $false
    $features = 'Microsoft-Hyper-V-All', 'Microsoft-Hyper-V', 'Microsoft-Hyper-V-Tools-All', 'Microsoft-Hyper-V-Management-PowerShell', 'Microsoft-Hyper-V-Hypervisor', 'Microsoft-Hyper-V-Services', 'Microsoft-Hyper-V-Management-Clients', 'Containers', 'VirtualMachinePlatform'

    if ($wsl) {
        $features += 'Microsoft-Windows-Subsystem-Linux'
    }

    foreach ($feature in $features) {
        if (Enable-MissingFeature -Name $feature) {
            Write-Log "!!! Restart is required after enabling WindowsFeature: $feature"
            $global:InstallRestartRequired = $true
        }
    }

    Write-Log 'Enable windows container version check skip'
    REG ADD 'HKLM\SYSTEM\CurrentControlSet\Control\Windows Containers' /v SkipVersionCheck /t REG_DWORD /d 2 /f

    if ($wsl) {
        Write-Log 'Disable Remote App authentication warning dialog'
        REG ADD 'HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' /V 'AuthenticationLevel' /T REG_DWORD /D '0' /F
    }

    if ($global:InstallRestartRequired) {
        Write-Log '!!! Restart is required. Reason: Changes in WindowsOptionalFeature !!!'
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
    if (($env:HTTP_Proxy).Length -eq 0 -and ($env:HTTPS_Proxy).Length -eq 0 ) {
        return
    }

    if (!$global:IP_Master) {
        throw "The calling script must include the file 'GlobalVariables.ps1' first!"
    }

    if (($env:NO_Proxy).Length -eq 0) {
        Write-Log 'You have configured proxies with environment variable HTTP_Proxy, but the NO_Proxy'
        Write-Log 'is not set. You have to configure NO_Proxy in the system environment variables.'
        Write-Log "NO_Proxy must be set to $global:IP_Master"
        Write-Log "Don't change the variable in the current shell only, that will not work!"
        Write-Log "After configuring the system environment variable, log out and log in!`n"
        throw "NO_Proxy must contain $global:IP_Master"
    }

    if (! ($env:NO_Proxy | Select-String -Pattern "\b$global:IP_Master\b")) {
        Write-Log 'You have configured proxies with environment variable HTTP_Proxy, but the NO_Proxy'
        Write-Log "doesn't contain $global:IP_Master. You have to configure NO_Proxy in the system environment variables."
        Write-Log "Don't change the variable in the current shell only, that will not work!"
        Write-Log "After configuring the system environment variable, log out and log in!`n"
        throw "NO_Proxy must contain $global:IP_Master"
    }
}

<#
.SYNOPSIS
    Copies the Kube config file from master node to local machine.
.DESCRIPTION
    Copies the Kube config file from master node to local machine.
.EXAMPLE
    Copy-KubeConfigFromMasterNode
#>
function Copy-KubeConfigFromMasterNode($Nested = $false) {
    # getting kube config from VM to windows host
    Write-Log "Retrieving kube config from master VM, writing to '$global:KubernetesPath\config'"
    Remove-Item -Path "$global:KubernetesPath\config" -Force -ErrorAction SilentlyContinue
    # checking cluster state
    $i = 0;
    while ($true) {
        $i++
        Write-Log "Handling loop for started cluster, checking kubeconfig availability (iteration $i):"
        Start-Sleep -s 3

        Write-Log 'Trying to get kube config from /etc/kubernetes/admin.conf'
        ExecCmdMaster 'sudo cp /etc/kubernetes/admin.conf /home' -Nested:$Nested
        Write-Log 'Trying to chmod file from /home/admin.conf'
        ExecCmdMaster 'sudo chmod 775 /home/admin.conf' -Nested:$Nested
        Write-Log 'Trying to scp file from /home/admin.conf'
        $source = "$global:Remote_Master" + ':/home/admin.conf'
        Copy-FromToMaster -Source $source -Target "$global:KubernetesPath\config"
        if (Test-Path "$global:KubernetesPath\config") {
            Write-Log "Kube config '$global:KubernetesPath\config' successfully retrieved !"
            break;
        }
        Write-Log '... kube config not yet available.'
        if ($i -eq 25) {
            throw 'timeout, kubernetes system was not started inside VM'
        }
    }
}

<#
.SYNOPSIS
    Create switch to KubeMaster VM.
.DESCRIPTION
    Create switch to KubeMaster VM.
#>
function New-KubeSwitch() {
    # create new switch for debian VM
    Write-Log "Create internal switch $global:SwitchName"
    New-VMSwitch -Name $global:SwitchName -SwitchType Internal -MinimumBandwidthMode Weight | Out-Null
    New-NetIPAddress -IPAddress $global:IP_NextHop -PrefixLength 24 -InterfaceAlias "vEthernet ($global:SwitchName)" | Out-Null
    # set connection to private because of firewall rules
    Set-NetConnectionProfile -InterfaceAlias "vEthernet ($global:SwitchName)" -NetworkCategory Private -ErrorAction SilentlyContinue
    # enable forwarding
    netsh int ipv4 set int "vEthernet ($global:SwitchName)" forwarding=enabled | Out-Null
    # change index in order to have the Ethernet card as first card (also for much better DNS queries)
    $ipindex1 = Get-NetIPInterface | ? InterfaceAlias -Like "*$global:SwitchName*" | ? AddressFamily -Eq IPv4 | select -expand 'ifIndex'
    Write-Log "Index for interface $global:SwitchName : ($ipindex1) -> metric 25"
    Set-NetIPInterface -InterfaceIndex $ipindex1 -InterfaceMetric 25
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

function Set-WSLSwitch() {
    $wslSwitch = 'WSL'
    Write-Log "Configuring internal switch $wslSwitch"

    $iteration = 60
    while ($iteration -gt 0) {
        $iteration--
        $ipindex = Get-NetAdapter -Name "vEthernet ($wslSwitch)" -ErrorAction SilentlyContinue | select -expand 'ifIndex'
        $oldIp = $null
        if ($ipindex) {
            $oldIp = (Get-NetIPAddress -InterfaceIndex $ipindex).IPAddress
        }
        if ($ipindex -and $oldIp) {
            Write-Log "ifindex of vEthernet ($wslSwitch): $ipindex"
            Write-Log "Old ip: $oldIp"
            if ($oldIp) {
                foreach ($ip in $oldIp) {
                    Remove-NetIPAddress -InterfaceIndex $ipindex -IPAddress $oldIp -Confirm:$False -ErrorAction SilentlyContinue
                }
            }

            break
        }

        Write-Log "No vEthernet ($wslSwitch) detected yet!"
        Start-Sleep 2
    }

    if ($iteration -eq 0) {
        throw "No vEthernet ($wslSwitch) found!"
    }

    New-NetIPAddress -IPAddress $global:IP_NextHop -PrefixLength 24 -InterfaceAlias "vEthernet ($wslSwitch)"
    # enable forwarding
    netsh int ipv4 set int "vEthernet ($wslSwitch)" forwarding=enabled | Out-Null
    # change index in order to have the Ethernet card as first card (also for much better DNS queries)
    $ipindex1 = Get-NetIPInterface | ? InterfaceAlias -Like "*$wslSwitch*" | ? AddressFamily -Eq IPv4 | select -expand 'ifIndex'
    Write-Log "Index for interface $wslSwitch : ($ipindex1) -> metric 25"
    Set-NetIPInterface -InterfaceIndex $ipindex1 -InterfaceMetric 25
}

function Start-WSL() {
    Restart-WinService 'WslService'
    Write-Log 'Disable Remote App authentication warning dialog'
    REG ADD 'HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' /V 'AuthenticationLevel' /T REG_DWORD /D '0' /F

    Write-Log 'Start KubeMaster with WSL2'
    Start-Process wsl -WindowStyle Hidden
}

<#
.SYNOPSIS
    Remove switch to KubeMaster VM.
.DESCRIPTION
    Remove switch to KubeMaster VM.
#>
function Remove-KubeSwitch() {
    # Remove old switch
    Write-Log 'Remove KubeSwitch'
    $vm = Get-VMNetworkAdapter -VMName $global:VMName -ErrorAction SilentlyContinue
    if ( $vm ) {
        $vm | Disconnect-VMNetworkAdapter
    }
    $sw = Get-VMSwitch -Name $global:SwitchName -ErrorAction SilentlyContinue
    if ( $sw ) {
        Remove-VMSwitch -Name $global:SwitchName -Force
    }
}

<#
.SYNOPSIS
    Connect switch to KubeMaster VM.
.DESCRIPTION
    Connect switch to KubeMaster VM.
#>
function Connect-KubeSwitch() {
    Write-Log 'Connect KubeSwitch to VM'
    # connect VM to switch
    $ad = Get-VMNetworkAdapter -VMName $global:VMName
    if ( !($ad) ) {
        Write-Log "Adding network adapter to VM '$global:VMName' ..."
        Add-VMNetworkAdapter -VMName $global:VMName -Name 'Network Adapter'
    }
    Connect-VMNetworkAdapter -VMName $global:VMName -SwitchName $global:SwitchName
}

<#
.SYNOPSIS
    Installs and initializes the KubeMaster VM.
.DESCRIPTION
    Installs and initializes the KubeMaster VM.

.PARAMETER VMStartUpMemory
    Startup memory (RAM) size for KubeMaster VM

.PARAMETER VMDiskSize
    Virtual hard disk size for KubeMaster VM

.PARAMETER VMProcessorCount
    Number of virtual processors for KubeMaster VM

.PARAMETER InstallationStageProxy
    The proxy to use during installation

.PARAMETER OperationStageProxy
    The proxy to use during operation

.PARAMETER DeleteFilesForOfflineInstallation
    Deletes the needed files to perform an offline installation

.PARAMETER ForceOnlineInstallation
    Forces the installation online

.EXAMPLE
    Install-AndInitKubemaster -VMStartUpMemory 4GB -VMProcessorCount 4 -VMDiskSize $50GB
#>
function Install-AndInitKubemaster {
    param (
        [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available to be used during installation')]
        [string] $InstallationStageProxy = '',
        [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy to be used during operation')]
        [string] $OperationStageProxy,
        [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of KubeMaster VM')]
        [long] $VMStartUpMemory = 4GB,
        [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for KubeMaster VM')]
        [long] $VMProcessorCount = 4,
        [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of KubeMaster VM')]
        [long] $VMDiskSize = 50GB,
        [parameter(Mandatory = $false, HelpMessage = 'Host-GW or VXLAN, Host-GW: true, false for VXLAN')]
        [bool] $HostGW = $true,
        [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
        [Boolean] $DeleteFilesForOfflineInstallation = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Forces the installation online')]
        [Boolean] $ForceOnlineInstallation = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Use WSL2 for hosting KubeMaster VM')]
        [switch] $WSL = $false,
        [parameter(Mandatory = $false, HelpMessage = 'The path to the vhdx with Ubuntu inside.')]
        [string] $LinuxVhdxPath = '',
        [parameter(Mandatory = $false, HelpMessage = 'The user name to access the computer with Ubuntu inside.')]
        [string] $LinuxUserName = '',
        [parameter(Mandatory = $false, HelpMessage = 'The password associated with the user name to access the computer with Ubuntu inside.')]
        [string] $LinuxUserPwd = ''
    )

    Write-Log 'Using proxies:'
    Write-Log "    - installation stage: '$InstallationStageProxy'"
    Write-Log "    - operation stage: '$OperationStageProxy'"

    Write-Log "VM '$global:VMName' is not yet available, creating VM ..."
    & "$global:KubernetesPath\smallsetup\kubemaster\InstallKubeMaster.ps1" -MemoryStartupBytes $VMStartUpMemory -MasterVMProcessorCount $VMProcessorCount -MasterDiskSize $VMDiskSize -InstallationStageProxy $InstallationStageProxy -OperationStageProxy $operationStageProxy -HostGW $HostGW -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation -ForceOnlineInstallation $ForceOnlineInstallation -WSL:$WSL -LinuxVhdxPath $LinuxVhdxPath -LinuxUserName $LinuxUserName -LinuxUserPwd $LinuxUserPwd

    # add DNS proxy at KubeSwitch for cluster searches
    if ($WSL) {
        Add-DnsServer $global:WSLSwitchName
    }
    else {
        Add-DnsServer $global:SwitchName
    }
}

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

function Stop-ServiceAndSetToManualStart($serviceName) {
    $svc = $(Get-Service -Name $serviceName -ErrorAction SilentlyContinue).Status
    if (($svc)) {
        $nssm = "$global:NssmInstallDirectory\nssm.exe"
        if (!(Test-Path $nssm)) {
            $nssm = "$global:NssmInstallDirectoryLegacy\nssm.exe"
        }
        Write-Log ('Stopping service and set to manual startup: ' + $serviceName)
        Stop-Service $serviceName
        &$nssm set $serviceName Start SERVICE_DEMAND_START | Out-Null
    }
}

# run command silently to suppress non-error output that get treated as errors
function Invoke-ExpressionAndCheckExitCode($commandExpression) {
    $tempErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'

    Invoke-Expression $commandExpression

    if ($LastExitCode -ne 0) {
        Write-Log "Command caused silently an unknown error. Re-running this command with `$ErrorActionPreference = 'Stop' to catch the error message..."

        $ErrorActionPreference = 'Stop'

        Invoke-Expression $commandExpression
    }

    $ErrorActionPreference = $tempErrorActionPreference
}

function Start-ServiceProcess($serviceName) {
    $svc = $(Get-Service -Name $serviceName -ErrorAction SilentlyContinue).Status
    if (($svc) -and ($svc -ne 'Running')) {
        Write-Log ('Starting service: ' + $serviceName)
        Start-Service -Name $serviceName -WarningAction SilentlyContinue
    }
}

function Stop-ServiceProcess($serviceName, $processName) {
    if ($(Get-Service -Name $serviceName -ErrorAction SilentlyContinue).Status -eq 'Running') {
        Write-Log ('Stopping running service: ' + $serviceName)
        Stop-Service -Name $serviceName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    }
    Stop-Process -Name $processName -Force -ErrorAction SilentlyContinue
}

function Add-DnsServer($switchname) {
    # add DNS proxy for cluster searches
    $ipindex = Get-NetIPInterface | ? InterfaceAlias -Like "*$switchname*" | ? AddressFamily -Eq IPv4 | select -expand 'ifIndex'
    Set-DnsClientServerAddress -InterfaceIndex $ipindex -ServerAddresses $global:IP_Master | Out-Null
    Set-DnsClient -InterfaceIndex $ipindex -ConnectionSpecificSuffix 'cluster.local' | Out-Null
}

function Reset-DnsServer($switchname) {
    $ipindex = Get-NetIPInterface | ? InterfaceAlias -Like "*$switchname*" | ? AddressFamily -Eq IPv4 | select -expand 'ifIndex'
    if ($ipindex) {
        Set-DnsClientServerAddress -InterfaceIndex $ipindex -ResetServerAddresses | Out-Null
        Set-DnsClient -InterfaceIndex $ipindex -ResetConnectionSpecificSuffix | Out-Null
    }
}

<#
.SYNOPSIS
    Sets the correct labels and taints for the nodes.
.DESCRIPTION
    Sets the correct labels and taints for the K8s nodes.
.PARAMETER WorkerMachineName
    Optional: Name of the (Windows) worker node
.EXAMPLE
    # consider control-plane-only (i.e. hostname in KubeMaster VM, e.g. kubemaster)
    Update-NodeLabelsAndTaints
.EXAMPLE
    # consider control-plane and (Windows) worker node
    Update-NodeLabelsAndTaints -WorkerMachineName 'my-win-machine'
#>
function Update-NodeLabelsAndTaints {
    param (
        [Parameter(Mandatory = $false)]
        [string] $WorkerMachineName
    )
    Write-Log 'Updating node labels and taints...'
    Write-Log 'Waiting for K8s API server to be ready...'

    Wait-ForAPIServer

    $controlPlaneTaint = 'node-role.kubernetes.io/control-plane'

    # mark control-plane as worker (remove the control-plane tainting)
    (&$global:KubectlExe get nodes -o=jsonpath='{range .items[*]}~{.metadata.name}#{.spec.taints[*].key}') -split '~' | ForEach-Object {
        $parts = $_ -split '#'

        if ($parts[1] -match $controlPlaneTaint) {
            $node = $parts[0]

            Write-Log "Taint '$controlPlaneTaint' found on node '$node', untainting..."

            &$global:KubectlExe taint nodes $node "$controlPlaneTaint-"
        }
    }

    if ([string]::IsNullOrEmpty($WorkerMachineName) -eq $false) {
        $nodeName = $WorkerMachineName.ToLower()

        Write-Log "Labeling and tainting worker node '$nodeName'..."

        # mark nodes as worker
        &$global:KubectlExe label nodes $nodeName kubernetes.io/role=worker --overwrite

        # taint windows nodes
        &$global:KubectlExe taint nodes $nodeName OS=Windows:NoSchedule --overwrite
    }

    # change default policy in VM (after restart of VM always policy is changed automatically)
    Write-Log 'Reconfiguring volatile settings in VM...'
    ExecCmdMaster 'sudo iptables --policy FORWARD ACCEPT'
    ExecCmdMaster 'sudo sysctl fs.inotify.max_user_instances=8192'
    ExecCmdMaster 'sudo sysctl fs.inotify.max_user_watches=524288'
    Write-Log "`n"
}

function Invoke-HookAfterVmInitialized {
    param (
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = ''
    )
    Invoke-Hook -HookName 'AfterVmInitialized' -AdditionalHooksDir $AdditionalHooksDir
}

function Set-IndexForDefaultSwitch {
    # Change index for default switch (on some computers the index is lower as for the main interface Ethernet)
    $ipindexDefault = Get-NetIPInterface | ? InterfaceAlias -Like '*Default*' | ? AddressFamily -Eq IPv4 | select -expand 'ifIndex'
    if ( $ipindexDefault ) {
        Write-Log "Index for interface Default : ($ipindexDefault) -> metric 35"
        Set-NetIPInterface -InterfaceIndex $ipindexDefault -InterfaceMetric 35
    }
}

function Set-SpecificVFPRules {
    $file = "$global:KubernetesPath\bin\cni\vfprules.json"
    $oldfile = "$global:KubernetesPath\cni\bin\vfprules.json"
    Remove-Item -Path $oldfile -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $file -Force -ErrorAction SilentlyContinue
    $clusterConfig = Get-Content $global:JsonConfigFile | Out-String | ConvertFrom-Json
    $smallsetup = $clusterConfig.psobject.properties['smallsetup'].value
    $smallsetup.psobject.properties['vfprules-multivm'].value | ConvertTo-Json | Out-File "$global:KubernetesPath\bin\cni\vfprules.json" -Encoding ascii
    Write-Log "Created new version of $file for multivm"
}

function Get-L2BridgeNIC {
    return $global:LoopbackAdapter
}

function CreateExternalSwitch {
    param (
        [Parameter()]
        [string] $adapterName
    )

    $nic = Get-NetIPAddress -InterfaceAlias $adapterName -ErrorAction SilentlyContinue
    if ($nic) {
        $ipaddress = $nic.IPv4Address
        $dhcp = $nic.PrefixOrigin
        Write-Log "Using card: '$adapterName' with $ipaddress and $dhcp"
    }
    else {
        Write-Log 'FAILURE: no NIC found which is appropriate !'
        throw 'Fatal: no network interface found which works for K2s Setup!'
    }

    # get DNS server from NIC
    $dnsServers = @(Get-DnsClientServerAddress -InterfaceIndex $nic.InterfaceIndex -AddressFamily IPv4)
    $adr = $('8.8.8.8', '8.8.4.4')
    if ( $dnsServers) {
        if ($dnsServers.ServerAddresses) {
            $adr = $dnsServers.ServerAddresses
        }
    }
    Write-Log "DNS servers found: '$adr'"
    # build string for DNS server
    $dnsserver = $($adr -join ',')

    # start of external switch
    Write-Log "Create l2 bridge network with subnet: $global:ClusterCIDR_Host, switch name: $global:L2BridgeSwitchName, DNS server: $dnsserver, gateway: $global:ClusterCIDR_Gateway, NAT exceptions: $global:ClusterCIDR_NatExceptions, adapter name: $adapterName"
    $netResult = New-HnsNetwork -Type 'L2Bridge' -Name "$global:L2BridgeSwitchName" -AdapterName "$adapterName" -AddressPrefix "$global:ClusterCIDR_Host" -Gateway "$global:ClusterCIDR_Gateway" -DNSServer "$dnserver"
    Write-Log $netResult

    # create endpoint
    $cbr0 = Get-HnsNetwork | Where-Object -FilterScript { $_.Name -EQ "$global:L2BridgeSwitchName" }
    if ( $null -Eq $cbr0 ) {
        throw 'No l2 bridge found. Please do a stopk8s ans start from scratch !'
    }

    $endpointname = $global:L2BridgeSwitchName + '_ep'
    $hnsEndpoint = New-HnsEndpoint -NetworkId $cbr0.ID -Name $endpointname -IPAddress $global:ClusterCIDR_NextHop -Verbose -EnableOutboundNat -OutboundNatExceptions $global:ClusterCIDR_NatExceptions
    if ($null -Eq $hnsEndpoint) {
        throw 'Not able to create a endpoint. Please do a stopk8s and restart again. Aborting.'
    }

    Attach-HnsHostEndpoint -EndpointID $hnsEndpoint.Id -CompartmentID 1
    $iname = "vEthernet ($endpointname)"
    netsh int ipv4 set int $iname for=en | Out-Null
    #netsh int ipv4 add neighbors $iname $global:ClusterCIDR_Gateway '00-01-e8-8b-2e-4b' | Out-Null
}

function RemoveExternalSwitch () {
    Write-Log "Remove l2 bridge network switch name: $global:L2BridgeSwitchName"
    Get-HnsNetwork | Where-Object Name -Like "$global:L2BridgeSwitchName" | Remove-HnsNetwork
}

function Set-InterfacePrivate {
    param (
        [Parameter()]
        [string] $InterfaceAlias
    )

    $iteration = 60
    while ($iteration -gt 0) {
        $iteration--
        Set-NetConnectionProfile -InterfaceAlias $InterfaceAlias -NetworkCategory Private -ErrorAction SilentlyContinue

        if ($?) {
            if ($((Get-NetConnectionProfile -interfacealias $InterfaceAlias).NetworkCategory) -eq 'Private') {
                break
            }
        }

        Write-Log "$InterfaceAlias not set to private yet..."
        Start-Sleep 5
    }

    if ($iteration -eq 0 -and $((Get-NetConnectionProfile -interfacealias $InterfaceAlias).NetworkCategory) -ne 'Private') {
        throw "$InterfaceAlias could not set to private in time"
    }

    Write-Log "OK: $InterfaceAlias set to private now"
}

function Get-TransparentProxy($Proxy) {
    if ( $Proxy -ne '' ) {
        Write-Log "Global proxy was set and will be used: $Proxy"
        return $Proxy
    }
    else {
        # get interface index
        # $nic = Get-L2BridgeNIC
        # if ( $null -Eq $nic ) {
        #     Write-Log "FAILURE: no NIC found which is appropriate !"
        #     throw 'Fatal: no network interface found which works for Small K8s Setup !'
        # }
        # $localproxy = "http://" + $nic.IPv4Address + ":8181"
        # $ret = $localproxy.replace(' ' , '')
        # Write-Host "[$(Get-Date -Format HH:mm:ss)] Local proxy will be used: $ret"
        $ret = 'http://' + $global:IP_NextHop + ':8181'
        return $ret
    }
}

function Set-IPAdressAndDnsClientServerAddress {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $IPAddress = $(throw 'Please specify the target IP address.'),
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $DefaultGateway = $(throw 'Please specify the default gateway.'),
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [UInt32] $Index = $(throw 'Please specify index of card.'),
        [Parameter(Mandatory = $False)]
        [string[]]$DnsAddresses = @('8.8.8.8', '8.8.4.4')

    )
    New-NetIPAddress -IPAddress $IPAddress -PrefixLength 24 -InterfaceIndex $Index -DefaultGateway $DefaultGateway -ErrorAction SilentlyContinue | Out-Null
    if ($DnsAddresses.Count -eq 0) {
        $DnsAddresses = $('8.8.8.8', '8.8.4.4')
    }
    Set-DnsClientServerAddress -InterfaceIndex $Index -Addresses $DnsAddresses

    if ( !(Test-Path "$global:KubernetesPath\bin\dnsproxy.yaml")) {
        Write-Log '           dnsproxy.exe is not configured, skipping DNS server config...'
        return
    }

    $nameServer = $DnsAddresses[0]
    $nameServerSet = Get-Content "$global:KubernetesPath\bin\dnsproxy.yaml" | Select-String -Pattern $DnsAddresses[0]

    if ( $nameServerSet ) {
        Write-Log '           DNS Server is already configured in dnsproxy.yaml (config for dnsproxy.exe)'
        return
    }

    #Last entry in the dnsproxy.yaml is reserved for default DNS Server, we will replace the default one with machine DNS server
    $existingNameServer = Get-Content "$global:KubernetesPath\bin\dnsproxy.yaml" | Select-String -Pattern '  -' | Select-Object -Last 1 | Select-Object -ExpandProperty Line
    $existingNameServer = $existingNameServer.Substring(4)
    Write-Log "           Existing DNS Address in dnsproxy.yaml $existingNameServer"
    Write-Log "           Updating dnsproxy.yaml (config for dnsproxy.exe) with DNS Address $nameServer"
    $newContent = Get-content "$global:KubernetesPath\bin\dnsproxy.yaml" | ForEach-Object { $_ -replace $existingNameServer, """$nameServer""" }
    $newContent | Set-Content "$global:KubernetesPath\bin\dnsproxy.yaml"
}

function Invoke-Hook {
    param (
        [parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $HookName = $(throw 'Please specify the hook to be executed.'),
        [parameter()]
        [string] $AdditionalHooksDir = ''
    )
    $hook = "$global:HookDir\\$HookName.ps1"
    if (Test-Path $hook) {
        &$hook
    }

    if ($AdditionalHooksDir -ne '') {
        $additionalHook = "$AdditionalHooksDir\\$HookName.ps1"
        if (Test-Path $additionalHook) {
            &$additionalHook
        }
    }
}

function Stop-InstallationIfDockerDesktopIsRunning {
    if ((Get-Service 'com.docker.service' -ErrorAction SilentlyContinue).Status -eq 'Running') {
        throw 'Docker Desktop is running! Please stop Docker Desktop in order to continue!'
    }
}

function Addk2sToDefenderExclusion {
    # Stop Microsoft Defender interference with K2s setup
    Add-MpPreference -Exclusionpath "$global:KubernetesPath" -ErrorAction SilentlyContinue
    Add-MpPreference -ExclusionProcess 'k2s.exe', 'vmmem.exe', 'vmcompute.exe', 'containerd.exe', 'kubelet.exe', 'httpproxy.exe', 'dnsproxy.exe', 'kubeadm.exe', 'kube-proxy.exe', 'bridge.exe', 'containerd-shim-runhcs-v1.exe' -ErrorAction SilentlyContinue
    Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
    Set-MpPreference -DisableBehaviorMonitoring $true -ErrorAction SilentlyContinue
}

function Wait-ForAPIServer () {
    $hostname = Get-ControlPlaneNodeHostname
    $iteration = 0
    while ($true) {
        $iteration++
        # try to apply the flannel resources
        $ErrorActionPreference = 'Continue'
        $result = $(echo yes | &$global:KubectlExe wait --timeout=60s --for=condition=Ready -n kube-system "pod/kube-apiserver-$hostname" 2>&1)
        $ErrorActionPreference = 'Stop'
        if ($result -match 'condition met') {
            break;
        }
        if ($iteration -eq 10) {
            Write-Log 'API Server could not be started up, aborting...'
            throw 'Unable to get the API Server running !'
        }
        Start-Sleep 2
    }
    if ($iteration -eq 1) {
        Write-Log 'API Server running, no waiting needed'
    }
    else {
        Write-Log 'API Server now running'
    }
}

function Get-ControlPlaneNodeHostname () {
    $hostname = Get-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_ControlPlaneNodeHostname
    return $hostname
}

function Save-ControlPlaneNodeHostname ($hostname) {
    Set-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_ControlPlaneNodeHostname -Value $hostname
    Write-Log "Saved VM hostname '$hostname' in file '$global:SetupJsonFile'"
}


<#
.SYNOPSIS
    Waits for the pods to become ready upto a specified duration
.DESCRIPTION
    Waits for all pods in a namespace satisfying a selector to become Ready. If the pods are not ready, it sleeps for a specified duration and queries pod
    status again until either all pods are ready or the number of retries are exhausted.
.PARAMETER Selector
    Identifies the pods to poll for becoming ready.
.PARAMETER Namespace
    Namespace in which the pods are present.
.PARAMETER ExpectedReadyPodCount
    Number of pods that should become ready.
.PARAMETER SleepDuration
    Duration in seconds to sleep between each retry
.PARAMETER NumberOfRetries
    Number of retries to perform for checking pods status.
.EXAMPLE
    Wait-ForPodsReady -Selector app=nginx -Namespace nginx -ExpectedReadyPodCount 3 -SleepDuration 10 -NumberOfRetries 60
#>
function Wait-ForPodsReady(
    [string]$Selector,
    [string]$Namespace = 'default',
    [int]$ExpectedReadyPodCount = 1,
    [int]$SleepDurationInSeconds = 10,
    [int]$NumberOfRetries = 10) {
    $allPodsUp = $false
    for (($i = 1); $i -le $NumberOfRetries; $i++) {
        $out = &$global:KubectlExe get pods --selector=$Selector -n $Namespace -o=jsonpath="{range .items[?(@.status.phase=='Running')]}{range @.status.containerStatuses[?(@.ready==`$true)]}{@.name}{'\n'}{end}{end}"
        $actualRunningPodCount = $out.Count
        if ($actualRunningPodCount -ne $ExpectedReadyPodCount) {
            $log = "Retry {$i}: Pods are not yet ready." +
            " Ready pod count : {$actualRunningPodCount}. Expected Ready Pod Count: {$ExpectedReadyPodCount}." +
            " Will retry after $SleepDurationInSeconds Seconds"
            Write-Log "$log" -Console
        }
        else {
            Write-Log 'All pods are running and ready for requests.' -Console
            $allPodsUp = $true
            break;
        }
        Start-Sleep -Seconds $SleepDurationInSeconds
    }
    return $allPodsUp
}

function Remove-ServiceIfExists($serviceName) {
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
        $nssm = "$global:NssmInstallDirectory\nssm.exe"
        if (!(Test-Path $nssm)) {
            $nssm = "$global:NssmInstallDirectoryLegacy\nssm.exe"
        }
        Write-Log ('Removing service: ' + $serviceName)
        Stop-Service -Force -Name $serviceName | Out-Null
        &$nssm remove $serviceName confirm
    }
}

function Get-StorageLocalDrive() {
    $storageLocalDriveLetter = ''

    $usedStorageLocalDriveLetter = Get-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_UsedStorageLocalDriveLetter
    if (!([string]::IsNullOrWhiteSpace($usedStorageLocalDriveLetter))) {
        $storageLocalDriveLetter = $usedStorageLocalDriveLetter
    }
    else {
        $searchAvailableFixedLogicalDrives = {
            $fixedHardDrives = Get-WmiObject -ClassName Win32_DiskDrive | Where-Object { $_.Mediatype -eq 'Fixed hard disk media' }
            $partitionsOnFixedHardDrives = $fixedHardDrives | Foreach-Object { Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskDrive.DeviceID=`"$($_.DeviceID.Replace('\','\\'))`"} WHERE AssocClass = Win32_DiskDriveToDiskPartition" }
            $fixedLogicalDrives = $partitionsOnFixedHardDrives | Foreach-Object { Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID=`"$($_.DeviceID)`"} WHERE AssocClass = Win32_LogicalDiskToPartition" }
            return $fixedLogicalDrives | Sort-Object $_.DeviceID
        }
        if ([string]::IsNullOrWhiteSpace($global:ConfiguredStorageLocalDriveLetter)) {
            $fixedLogicalDrives = $searchAvailableFixedLogicalDrives.Invoke()
            # no drive letter is configured --> use the local drive with the most space available
            $fixedLogicalDriveWithMostSpaceAvailable = $($fixedLogicalDrives | Sort-Object -Property FreeSpace -Descending | Select-Object -Property DeviceID -First 1).DeviceID
            $storageLocalDriveLetter = $fixedLogicalDriveWithMostSpaceAvailable.Substring(0, 1)
        }
        else {
            if ($global:ConfiguredStorageLocalDriveLetter -match '^[a-zA-Z]$') {
                $storageLocalDriveLetter = $global:ConfiguredStorageLocalDriveLetter
                $searchedLogicalDeviceID = $storageLocalDriveLetter + ':'
                $fixedLogicalDrives = $searchAvailableFixedLogicalDrives.Invoke()
                $foundFixedLogicalDrive = $fixedLogicalDrives | Where-Object { $_.DeviceID -eq $searchedLogicalDeviceID }
                if ($null -eq $foundFixedLogicalDrive) {
                    $availableFixedLogicalDrives = (($fixedLogicalDrives | Select-Object -Property DeviceID) | ForEach-Object { $_.DeviceID.Substring(0, 1) }) -join ', '
                    throw "The configured local drive letter '$global:ConfiguredStorageLocalDriveLetter' is not a local fixed drive or is not available in your system.`nYour available local fixed drives are: $availableFixedLogicalDrives. Please choose one of them."
                }
            }
            else {
                throw "The configured local drive letter '$global:ConfiguredStorageLocalDriveLetter' is syntactically wrong. Please choose just a valid letter of an available local fixed drive."
            }
        }

        Set-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_UsedStorageLocalDriveLetter -Value $storageLocalDriveLetter | Out-Null
    }

    if ([string]::IsNullOrWhiteSpace($storageLocalDriveLetter)) {
        throw 'The local drive letter for the storage could not be determined'
    }

    return $storageLocalDriveLetter + ':'
}

function Get-RegistryToken() {
    # Read the token from the file
    $token = Get-Content -Path "$global:KubernetesPath\bin\registry.dat" -Raw
    return [string]$token
}

function Update-SystemPath ($Action, $Addendum) {
    $regLocation =
    'Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment'
    $path = (Get-ItemProperty -Path $regLocation -Name PATH).path

    # Add an item to PATH
    if ($Action -eq 'add') {
        $path = $path + [IO.Path]::PathSeparator + $Addendum
        $path = ( $path -split [IO.Path]::PathSeparator | Select-Object -Unique ) -join [IO.Path]::PathSeparator
        Set-ItemProperty -Path $regLocation -Name PATH -Value $path

        $env:Path = $env:Path + [IO.Path]::PathSeparator + $Addendum
        $env:Path = ( $env:Path -split [IO.Path]::PathSeparator | Select-Object -Unique ) -join [IO.Path]::PathSeparator

        Write-Log "Added $Addendum to PATH variable"
    }

    # Remove an item from PATH
    if ($Action -eq 'remove') {
        $path = ($path.Split([IO.Path]::PathSeparator) | Where-Object { $_ -ne "$Addendum" }) -join [IO.Path]::PathSeparator
        Set-ItemProperty -Path $regLocation -Name PATH -Value $path
    }
}

function Set-EnvVars {
    Update-SystemPath -Action 'add' "$global:KubernetesPath"
    Update-SystemPath -Action 'add' "$global:KubernetesPath\bin"
    Update-SystemPath -Action 'add' "$global:KubernetesPath\bin\exe"
    Update-SystemPath -Action 'add' "$global:KubernetesPath\bin\docker"
    Update-SystemPath -Action 'add' "$global:KubernetesPath\bin\containerd"
}

function Reset-EnvVars {
    Update-SystemPath -Action 'remove' "$global:KubernetesPath"
    Update-SystemPath -Action 'remove' "$global:KubernetesPath\bin"
    Update-SystemPath -Action 'remove' "$global:KubernetesPath\bin\exe"
    Update-SystemPath -Action 'remove' "$global:KubernetesPath\bin\docker"
    Update-SystemPath -Action 'remove' "$global:KubernetesPath\containerd" # Backward compatibility
    Update-SystemPath -Action 'remove' "$global:KubernetesPath\bin\containerd"
}

<#
.SYNOPSIS
    Executes a given script
.DESCRIPTION
    Executes a given script as an external command. Wrapper for unit testing.
.PARAMETER FilePath
    Path to script file to execute. Throws if the file is not existing.
#>
function Invoke-Script {
    param (
        [parameter(Mandatory = $false)]
        [string] $FilePath = $(throw 'FilePath not specified')
    )
    if ((Test-Path $FilePath) -ne $true) {
        throw "Path to '$FilePath' not existing"
    }

    & $FilePath
}

<#
.SYNOPSIS
Wrapper for .NET function.

.DESCRIPTION
Wrapper for .NET function 'System.IO.Path.GetFileName()'

.PARAMETER FilePath
The file path to derive the file name from
#>
function Get-FileName {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $FilePath = $(throw 'File path not specified')
    )

    return [System.IO.Path]::GetFileName($FilePath)
}

<#
.SYNOPSIS
Write refresh info.

.DESCRIPTION
Write information about refersh of env variables
#>
function Write-RefreshEnvVariables {
    Write-Log ' ' -Console
    Write-Log '   Update PATH environment variable for proper usage:' -Console
    Write-Log ' ' -Console
    Write-Log "   Powershell: '$global:KubernetesPath\smallsetup\helpers\RefreshEnv.ps1'" -Console
    Write-Log "   Command Prompt: '$global:KubernetesPath\smallsetup\helpers\RefreshEnv.cmd'" -Console
    Write-Log '   Or open new shell' -Console
    Write-Log ' ' -Console
}

function Get-KubemasterBaseImagePath {
    $linuxOsType = Get-LinuxOsType
    $fileName = switch ( $linuxOsType ) {
        $global:LinuxOsType_DebianCloud { $global:KubemasterBaseImageName }
        $global:LinuxOsType_Ubuntu { $global:KubemasterBaseUbuntuImageName }
        Default { throw "The Linux OS type '$linuxOsType' is not supported." }
    }
    return "$global:BinDirectory\$fileName"
}

function Get-KubemasterRootfsPath {
    $linuxOsType = Get-LinuxOsType
    $fileName = switch ( $linuxOsType ) {
        $global:LinuxOsType_DebianCloud { $global:KubemasterRootfsName }
        $global:LinuxOsType_Ubuntu { $global:KubemasterUbuntuRootfsName }
        Default { throw "The Linux OS type '$linuxOsType' is not supported." }
    }
    return "$global:BinDirectory\$fileName"
}

function Get-LinuxOsType {
    $linuxOsType = Get-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_LinuxOsType

    if ([string]::IsNullOrWhiteSpace($linuxOsType)) {
        return $global:LinuxOsType_DebianCloud
    }
    return $linuxOsType
}

<#
.SYNOPSIS
Log Error Message and Throw Exception.

.DESCRIPTION
Based on ErrorActionPreference, error is logged and thrown to the caller
#>
function Log-ErrorWithThrow ([string]$ErrorMessage) {
    if ($ErrorActionPreference -eq 'Stop') {
        #If Stop is the ErrorActionPreference from the caller then Write-Error throws an exception which is not logged in k2s.log file.
        #So we need to write a warning to capture error message.
        Write-Warning "$ErrorMessage"
    }
    else {
        Write-Error "$ErrorMessage"
    }
    throw $ErrorMessage
}

<#
.SYNOPSIS
Performs time synchronization across all nodes of the clusters.
#>
function Perform-TimeSync {
    $timezoneStandardNameOnHost = (Get-TimeZone).StandardName
    [XML]$timezoneConfigXml = (Get-Content -Path $global:WindowsTimezoneConfig)
    $timezonesLinux = ($timezoneConfigXml.supplementalData.windowsZones.mapTimezones.mapZone | Where-Object { $_.other -eq "$timezoneStandardNameOnHost" }).type
    $canPerformTimeSync = $false
    if ($timezonesLinux.Count -eq 0) {
        Write-Log "No equivalent Linux time zone for Windows time zone $timezoneStandardNameOnHost was found. Cannot perform time synchronization" -Console
        Write-Log 'Please perform time synchronization manually.' -Console
    }
    else {
        $timezoneLinux = $timezonesLinux[0]
        $canPerformTimeSync = $true
    }

    if ($canPerformTimeSync) {
        Write-Log 'Performing time synchronization between nodes' -Console

        #Set timezone in kubemaster
        ExecCmdMaster "sudo timedatectl set-timezone $timezoneLinux 2>&1"

        #Set timezone in windows worker node for Multivm
        $setupType = Get-Installedk2sSetupType
        $linuxOnly = Get-LinuxOnlyFromConfig

        if ($setupType -eq $global:SetupType_MultiVMK8s -and $linuxOnly -ne $true) {
            $session = Open-RemoteSessionViaSSHKey $global:Admin_WinNode $global:WindowsVMKey

            Invoke-Command -Session $session {
                Set-TimeZone -Name $using:timezoneStandardNameOnHost
            }
        }
    }
}

function Get-RandomPassword {
    param (
        [Parameter(Mandatory)]
        [ValidateRange(4, [int]::MaxValue)]
        [int] $length,
        [int] $upper = 1,
        [int] $lower = 1,
        [int] $numeric = 1,
        [int] $special = 1
    )

    if ($upper + $lower + $numeric + $special -gt $length) {
        throw 'number of upper/lower/numeric/special char must be lower or equal to length'
    }

    $uCharSet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    $lCharSet = 'abcdefghijklmnopqrstuvwxyz'
    $nCharSet = '0123456789'
    $sCharSet = '/*-+!?()@:_#'
    $charSet = ''

    if ($upper -gt 0) { $charSet += $uCharSet }
    if ($lower -gt 0) { $charSet += $lCharSet }
    if ($numeric -gt 0) { $charSet += $nCharSet }
    if ($special -gt 0) { $charSet += $sCharSet }

    $charSet = $charSet.ToCharArray()

    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $bytes = New-Object byte[]($length)
    $rng.GetBytes($bytes)

    $result = New-Object char[]($length)
    for ($i = 0 ; $i -lt $length ; $i++) {
        $result[$i] = $charSet[$bytes[$i] % $charSet.Length]
    }
    $password = (-join $result)

    $valid = $true
    if ($upper -gt ($password.ToCharArray() | Where-Object { $_ -cin $uCharSet.ToCharArray() }).Count) { $valid = $false }
    if ($lower -gt ($password.ToCharArray() | Where-Object { $_ -cin $lCharSet.ToCharArray() }).Count) { $valid = $false }
    if ($numeric -gt ($password.ToCharArray() | Where-Object { $_ -cin $nCharSet.ToCharArray() }).Count) { $valid = $false }
    if ($special -gt ($password.ToCharArray() | Where-Object { $_ -cin $sCharSet.ToCharArray() }).Count) { $valid = $false }

    if (!$valid) {
        $password = Get-RandomPassword $length $upper $lower $numeric $special
    }

    return $password
}

function Stop-InstallIfNoMandatoryServiceIsRunning {
    $hns = Get-Service 'hns' -ErrorAction SilentlyContinue
    if (!($hns -and $hns.Status -eq 'Running')) {
        throw 'Host Network Service is not running. This is need for containers. Please enable prerequisites for K2s - https://github.com/Siemens-Healthineers/K2s !'
    }
    $hcs = Get-Service 'vmcompute' -ErrorAction SilentlyContinue
    if (!($hcs -and $hcs.Status -eq 'Running')) {
        throw 'Host Compute Service is not running. This is needed for containers. Please enable prerequisites for K2s - https://github.com/Siemens-Healthineers/K2s !'
    }
}