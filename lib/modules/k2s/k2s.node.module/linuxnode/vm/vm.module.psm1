# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

$configModule = "$PSScriptRoot\..\..\..\k2s.infra.module\config\config.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\k2s.infra.module\log\log.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\k2s.infra.module\path\path.module.psm1"
Import-Module $configModule, $pathModule, $logModule

$ipControlPlane = Get-ConfiguredIPControlPlane
$nameControlPlane = Get-ConfigControlPlaneNodeHostname
$defaultUserName = 'remote'
$remoteUser = "$defaultUserName@$ipControlPlane"
$remotePwd = 'admin'
$key = Get-SSHKeyControlPlane

$kubePath = Get-KubePath
$plinkExe = "$kubePath\bin\plink.exe"
$scpExe = "$kubePath\bin\pscp.exe"

# TODO Separate Linux distribution module
$LinuxOsTypeDebianCloud = 'DebianCloud'
$LinuxOsTypeUbuntu = 'Ubuntu'
$ControlPlaneVMBaseImageName = 'Kubemaster-Base.vhdx'
$ControlPlaneVMBaseUbuntuImageName = 'Kubemaster-Base-Ubuntu.vhdx'
$ControlPlaneVMRootfsName = 'Kubemaster-Base.rootfs.tar.gz'
$ControlPlaneVMUbuntuRootfsName = 'Kubemaster-Base-Ubuntu.rootfs.tar.gz'

function Invoke-SSHWithKey {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Command = $(throw 'Command not specified'),
        [Parameter(Mandatory = $false)]
        [switch]
        $Nested,
        [Parameter(Mandatory = $false)]
        [string] $IpAddress = $ipControlPlane,
        [string] $UserName = $defaultUserName
    )
    $userOnRemoteMachine = "$UserName@$IpAddress"
    $params = '-n', '-o', 'StrictHostKeyChecking=no', '-i', $key, $userOnRemoteMachine, $Command

    if ($Nested -eq $true) {
        # omit the "-n" param
        $params = $params[1..($params.Length - 1)]
    }

    &ssh.exe $params 2>&1 | ForEach-Object { Write-Log $_ -Console -Raw }
}

function Invoke-CmdOnControlPlaneViaSSHKey(
    [Parameter(Mandatory = $false)]
    $CmdToExecute,
    [Parameter(Mandatory = $false)]
    [switch]$IgnoreErrors = $false,
    [Parameter(Mandatory = $false)]
    [uint16]$Retries = 0,
    [Parameter(Mandatory = $false)]
    [uint16]$Timeout = 1,
    [Parameter(Mandatory = $false)]
    [switch]$NoLog = $false,
    [Parameter(Mandatory = $false , HelpMessage = 'When executing ssh.exe in nested environment[host=>VM=>VM], -n flag should not be used.')]
    [switch]$Nested = $false,
    [Parameter(Mandatory = $false, HelpMessage = 'repair CMD for the case first run did not work out')]
    [string]$RepairCmd = $null) {

    $invocationParams = @{
        CmdToExecute = $CmdToExecute
        IgnoreErrors = $IgnoreErrors
        Retries      = $Retries
        Timeout      = $Timeout
        NoLog        = $NoLog
        Nested       = $Nested
        RepairCmd    = $RepairCmd
        IpAddress    = $ipControlPlane
    }
    return Invoke-CmdOnVmViaSSHKey @invocationParams
}

function Invoke-CmdOnVmViaSSHKey(
    [Parameter(Mandatory = $false)]
    $CmdToExecute,
    [Parameter(Mandatory = $false)]
    [switch]$IgnoreErrors = $false,
    [Parameter(Mandatory = $false)]
    [uint16]$Retries = 0,
    [Parameter(Mandatory = $false)]
    [uint16]$Timeout = 1,
    [Parameter(Mandatory = $false)]
    [switch]$NoLog = $false,
    [Parameter(Mandatory = $false , HelpMessage = 'When executing ssh.exe in nested environment[host=>VM=>VM], -n flag should not be used.')]
    [switch]$Nested = $false,
    [Parameter(Mandatory = $false, HelpMessage = 'repair CMD for the case first run did not work out')]
    [string]$RepairCmd = $null,
    [Parameter(Mandatory = $false)]
    [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
    [string]$UserName = $defaultUserName) {

    if (!$NoLog) {
        Write-Log "cmd: $CmdToExecute, retries: $Retries, timeout: $Timeout sec, ignore err: $IgnoreErrors, nested: $Nested, ip address: $IpAddress"
    }
    $Stoploop = $false
    [uint16]$Retrycount = 1
    do {
        try {
            $output = Invoke-SSHWithKey -Command $CmdToExecute -Nested:$Nested -UserName $UserName -IpAddress $IpAddress
            $success = ($LASTEXITCODE -eq 0)

            if (!$success -and !$IgnoreErrors) {
                throw "Error occurred while executing command '$CmdToExecute' in control plane (exit code: '$LASTEXITCODE')"
            }
            $Stoploop = $true
        }
        catch {
            Write-Log $_
            if ($Retrycount -gt $Retries) {
                $Stoploop = $true
            }
            else {
                Write-Log "cmd: $CmdToExecute will be retried.."

                if ($null -ne $RepairCmd -and !$IgnoreErrors) {
                    Write-Log "Executing repair cmd: $RepairCmd"

                    Invoke-SSHWithKey -Command $RepairCmd -Nested:$Nested -UserName $UserName -IpAddress $IpAddress
                }

                Start-Sleep -Seconds $Timeout
                $Retrycount = $Retrycount + 1
            }
        }
    }
    While ($Stoploop -eq $false)

    return [pscustomobject]@{ Success = $success; Output = $output }
}

function Invoke-CmdOnControlPlaneViaUserAndPwd(
    [Parameter(Mandatory = $false)]
    $CmdToExecute,
    [Parameter(Mandatory = $false)]
    [switch]$IgnoreErrors = $false,
    [Parameter(Mandatory = $false)]
    [uint16]$Retries = 0,
    [Parameter(Mandatory = $false)]
    [uint16]$Timeout = 2,
    [Parameter(Mandatory = $false)]
    [string]$RemoteUser = $remoteUser,
    [Parameter(Mandatory = $false)]
    [string]$RemoteUserPwd = $remotePwd,
    [Parameter(Mandatory = $false)]
    [switch]$NoLog = $false,
    [Parameter(Mandatory = $false)]
    [string]$RepairCmd = $null) {
    if (!$NoLog) {
        Write-Log "cmd: $CmdToExecute, retries: $Retries, timeout: $Timeout sec, ignore err: $IgnoreErrors"
    }
    $Stoploop = $false
    [uint16]$Retrycount = 1
    do {
        try {
            $output = &"$plinkExe" -ssh -4 $RemoteUser -pw $RemoteUserPwd -no-antispoof $CmdToExecute 2>&1 | ForEach-Object { Write-Log $_ -Console -Raw }
            $success = ($LASTEXITCODE -eq 0)
            if (!$success -and !$IgnoreErrors) { throw "Error occurred while executing command '$CmdToExecute' (exit code: '$LASTEXITCODE')" }
            $Stoploop = $true
        }
        catch {
            Write-Log $_
            if ($Retrycount -gt $Retries) {
                $Stoploop = $true
            }
            else {
                Write-Log "cmd: $CmdToExecute will be retried.."

                # try to repair the command
                if ( ($null -ne $RepairCmd) -and !$IgnoreErrors) {
                    Write-Log "Executing repair cmd: $RepairCmd"
                    &"$plinkExe" -ssh -4 $RemoteUser -pw $RemoteUserPwd -no-antispoof $RepairCmd 2>&1 | ForEach-Object { Write-Log $_ -Console -Raw }
                }

                Start-Sleep -Seconds $Timeout
                $Retrycount = $Retrycount + 1
            }
        }
    }
    While ($Stoploop -eq $false)

    return [pscustomobject]@{ Success = $success; Output = $output }
}

function Get-IsControlPlaneRunning {
    $vmNode = Get-VM -Name $nameControlPlane -ErrorAction SilentlyContinue

    if ($null -eq ($vmNode)) {
        return $false
    }

    $masterVmState = ($vmNode).State
    return $masterVmState -eq [Microsoft.HyperV.PowerShell.VMState]::Running
}

function Copy-FromControlPlaneViaSSHKey($Source, $Target,
    [Parameter(Mandatory = $false)]
    [switch]$IgnoreErrors = $false) {
    Write-Log "Copying '$Source' to '$Target', ignoring errors: '$IgnoreErrors'"

    $linuxSourceDirectory = $Source -replace "${remoteUser}:", ''
    $leaf = Split-Path $linuxSourceDirectory -Leaf
    $filter = $leaf

    ssh.exe -n -o StrictHostKeyChecking=no -i $key $remoteUser "[ -d '$linuxSourceDirectory' ]"
    $isDir = $?

    if ($leaf.Contains("*")) {
        # copy all/specific files in directory e.g. pvc-* or *
        (Invoke-CmdOnControlPlaneViaSSHKey 'sudo mkdir /tmp/matchedFilesCopyFromControlPlaneViaSSHKey').Output | Write-Log
        (Invoke-CmdOnControlPlaneViaSSHKey "cd `$(dirname '$linuxSourceDirectory') && find . -name '$filter' | sudo xargs -i cp --parents {} -r /tmp/matchedFilesCopyFromControlPlaneViaSSHKey").Output | Write-Log

        $tarFolder = "/tmp/matchedFilesCopyFromControlPlaneViaSSHKey"
        $targetDirectory = $Target
    } elseif ($isDir) {
        # single folder copy
        $tarFolder = $linuxSourceDirectory
        $targetDirectory = "$Target\$leaf"
    } else {
        $output = scp.exe -o StrictHostKeyChecking=no -r -i $key "${remoteUser}:$Source" "$Target" 2>&1
        if ($LASTEXITCODE -ne 0 -and !$IgnoreErrors) {
            throw "Could not copy '$Source' to '$Target': $output"
        }
        Write-Log $output
        return
    }

    (Invoke-CmdOnControlPlaneViaSSHKey 'sudo rm -rf /tmp/copy.tar').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey "sudo tar -cf /tmp/copy.tar -C $tarFolder .").Output | Write-Log

    $output = scp.exe -o StrictHostKeyChecking=no -i $key "${remoteUser}:/tmp/copy.tar" "$env:temp\copy.tar" 2>&1
    if ($LASTEXITCODE -ne 0 -and !$IgnoreErrors) {
        throw "Could not copy '$Source' to '$Target': $output"
    }
    Write-Log $output

    New-Item -Path "$targetDirectory" -ItemType Directory -ErrorAction SilentlyContinue | Out-Null

    $output = tar.exe -xf "$env:temp\copy.tar" -C "$targetDirectory"
    if ($LASTEXITCODE -ne 0 -and !$IgnoreErrors) {
        throw "Could not copy '$Source' to '$Target': $output"
    }
    Write-Log $output

    (Invoke-CmdOnControlPlaneViaSSHKey 'sudo rm -rf /tmp/copy.tar').Output | Write-Log
    Remove-Item -Path "$env:temp\copy.tar" -Force -ErrorAction SilentlyContinue
    (Invoke-CmdOnControlPlaneViaSSHKey 'sudo rm -rf /tmp/matchedFilesCopyFromControlPlaneViaSSHKey').Output | Write-Log
}

function Copy-FromRemoteComputerViaUserAndPwd($Source, $Target, $IpAddress,
    [Parameter(Mandatory = $false)]
    [switch]$IgnoreErrors = $false) {
    Write-Log "Copying '$Source' to '$Target' at '$IpAddress', ignoring errors: '$IgnoreErrors'"

    $output = Write-Output yes | &"$scpExe" -ssh -4 -q -r -pw $remotePwd "${defaultUserName}@${IpAddress}:$Source" "$Target" 2>&1

    if ($LASTEXITCODE -ne 0 -and !$IgnoreErrors) {
        throw "Could not copy '$Source' to '$Target': $output"
    }
    Write-Log $output
}

function Copy-ToControlPlaneViaSSHKey($Source, $Target,
    [Parameter(Mandatory = $false)]
    [switch]$IgnoreErrors = $false) {
    
    Copy-ToRemoteComputerViaSshKey -Source $Source -Target $Target -UserName $defaultUserName -IpAddress $ipControlPlane -IgnoreErrors:$IgnoreErrors
}

function Copy-ToRemoteComputerViaSshKey($Source, $Target, $UserName, $IpAddress,
    [Parameter(Mandatory = $false)]
    [switch]$IgnoreErrors = $false) {
    Write-Log "Copying '$Source' to '$Target', ignoring errors: '$IgnoreErrors'"

    $remoteComputerUser = "$UserName@$IpAddress"

    $leaf = Split-Path $Source -leaf
    $targetDirectory = $Target -replace "${remoteComputerUser}:", ''

    $tempDirectory = "$env:TEMP\matchedFilesCopyToRemoteComputerViaSSHKey"
    if ($leaf.Contains("*")) {
        # copy all/specific files in directory e.g. pvc-* or *
        $filter = $leaf

        New-Item -Path "$tempDirectory" -ItemType Directory -Force | Out-Null
        Get-ChildItem -Path $(Split-Path $Source -Parent) -Filter $filter -Force | ForEach-Object {
            Write-Log "  Adding '$($_.FullName)'.."
            Copy-Item "$($_.FullName)" "$tempDirectory" -Force -Recurse
        }

        $tarFolder = "$tempDirectory"
    } elseif ($(Test-Path $Source) -and (Get-Item $Source) -is [System.IO.DirectoryInfo]) {
        # single folder copy
        $tarFolder = $Source
        $targetDirectory = "$targetDirectory/$leaf"
    } else {
         # single file copy
        $output = scp.exe -o StrictHostKeyChecking=no -r -i $key "$Source" "${remoteComputerUser}:$Target" 2>&1
        if ($LASTEXITCODE -ne 0 -and !$IgnoreErrors) {
            throw "Could not copy '$Source' to '$Target': $output"
        }
        Write-Log $output
        return
    }

    (Invoke-CmdOnControlPlaneViaSSHKey 'sudo rm -rf /tmp/copy.tar').Output | Write-Log

    $output = tar.exe -cf "$env:TEMP\copy.tar" -C $tarFolder .
    if ($LASTEXITCODE -ne 0 -and !$IgnoreErrors) {
        throw "Could not copy '$Source' to '$Target': $output"
    }

    $output = scp.exe -o StrictHostKeyChecking=no -i $key "$env:temp\copy.tar" "${remoteComputerUser}:/tmp" 2>&1
    if ($LASTEXITCODE -ne 0 -and !$IgnoreErrors) {
        throw "Could not copy '$Source' to '$Target': $output"
    }

    (Invoke-CmdOnControlPlaneViaSSHKey "mkdir -p $targetDirectory").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey "tar -xf /tmp/copy.tar -C $targetDirectory").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey 'sudo rm -rf /tmp/copy.tar').Output | Write-Log
    Remove-Item -Path "$env:temp\copy.tar" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$tempDirectory" -Force -Recurse -ErrorAction SilentlyContinue
}

function Copy-ToControlPlaneViaUserAndPwd($Source, $Target,
    [Parameter(Mandatory = $false)]
    [switch]$IgnoreErrors = $false) {
    Write-Log "Copying '$Source' to '$Target', ignoring errors: '$IgnoreErrors'"

    $output = Write-Output yes | &"$scpExe" -ssh -4 -q -r -pw $remotePwd "$Source" "${remoteUser}:$Target" 2>&1

    if ($LASTEXITCODE -ne 0 -and !$IgnoreErrors) {
        throw "Could not copy '$Source' to '$Target': $output"
    }
    Write-Log $output
}

function Copy-ToRemoteComputerViaUserAndPwd($Source, $Target, $IpAddress,
    [Parameter(Mandatory = $false)]
    [switch]$IgnoreErrors = $false) {
    Write-Log "Copying '$Source' to '$Target', ignoring errors: '$IgnoreErrors'"

    $output = Write-Output yes | &"$scpExe" -ssh -4 -q -r -pw $remotePwd "$Source" "${defaultUserName}@${IpAddress}:$Target" 2>&1

    if ($LASTEXITCODE -ne 0 -and !$IgnoreErrors) {
        throw "Could not copy '$Source' to '$Target': $output"
    }
    Write-Log $output
}

function Test-ControlPlanePrerequisites(
    [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for Control Plane VM (Linux)')]
    [long] $MasterVMProcessorCount,
    [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of Control Plane VM (Linux)')]
    [long] $MasterVMMemory,
    [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of Control Plane VM (Linux)')]
    [uint64] $MasterDiskSize) {

    Write-Log "Using Control Plane VM ProcessorCount: $MasterVMProcessorCount"
    Write-Log "Using Control Plane VM Memory: $([math]::round($MasterVMMemory/1GB, 2))GB"
    Write-Log "Using Control Plane VM Diskspace: $([math]::round($MasterDiskSize/1GB, 2))GB"

    # check memory
    if ( $MasterVMMemory -lt 2GB ) {
        Write-Log 'k2s needs minimal 2GB main memory, you have passed a lower value!' -Error
        throw '[PREREQ-FAILED] Master node memory passed too low'
    }

    # check disk
    $defaultProvisioningBaseImageSize = Get-DefaultProvisioningBaseImageDiskSize
    if ( $MasterDiskSize -lt $defaultProvisioningBaseImageSize ) {
        Write-Log "k2s needs minimal $defaultProvisioningBaseImageSize disk space, you have passed a lower value!" -Error
        throw '[PREREQ-FAILED] Master VM Disk size passed too low'
    }

    #Check for running VMs and minikube
    $runningVMs = Get-VM -ErrorAction SilentlyContinue | Where-Object { $_.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running }
    if ($runningVMs) {
        Write-Log 'Active Hyper-V VM:'
        Write-Log $($runningVMs | Select-Object -Property Name)
        if ($runningVMs | Where-Object Name -eq 'minikube') {
            throw "[PREREQ-FAILED] Minikube must be stopped before running the installer, do 'minikube stop'"
        }
    }

    # Check for external switches
    Test-ExistingExternalSwitch

    if (Get-VM -ErrorAction SilentlyContinue -Name $nameControlPlane) {
        throw "[PREREQ-FAILED] $nameControlPlane VM must not exist before installation, please perform k2s uninstall"
    }
}

function Test-ExistingExternalSwitch {
    $l2BridgeSwitchName = Get-L2BridgeSwitchName
    $externalSwitches = Get-VMSwitch | Where-Object { $_.SwitchType -eq 'External' -and $_.Name -ne $l2BridgeSwitchName}
    if ($externalSwitches) {
        Write-Log 'Found External Switches:'
        Write-Log $($externalSwitches | Select-Object -Property Name)
        Write-Log 'Precheck failed: Cannot proceed further with existing External Network Switches as it conflicts with k2s networking' -Console
        Write-Log "Remove all your External Network Switches with command PS>Get-VMSwitch | Where-Object { `$_.SwitchType -eq 'External'  -and `$_.Name -ne '$l2BridgeSwitchName'} | Remove-VMSwitch -Force" -Console
        Write-Log 'WARNING: This will remove your External Switches, please check whether these switches are required before executing the command' -Console
        throw '[PREREQ-FAILED] Remove all the existing External Network Switches and retry the k2s command again'
    }

}

function Get-IsLinuxOsDebian {
    return ((Get-ConfigLinuxOsType) -eq $LinuxOsTypeDebianCloud)
}

function Get-LinuxOsType($LinuxVhdxPath) {
    $linuxOsType = $LinuxOsTypeDebianCloud
    if (!([string]::IsNullOrWhiteSpace($LinuxVhdxPath))) {
        if (!(Test-Path $LinuxVhdxPath)) {
            throw "The specified file in the path '`$LinuxVhdxPath' does not exist"
        }
        $fileExtension = (Get-Item $LinuxVhdxPath).Extension
        if (!($fileExtension -eq '.vhdx')) {
            throw ('Disk is not a vhdx or vhd disk.' )
        }

        $linuxOsType = $LinuxOsTypeUbuntu
    }
    return $linuxOsType
}

function Get-ControlPlaneVMBaseImagePath {
    $linuxOsType = Get-LinuxOsType
    $fileName = switch ( $linuxOsType ) {
        $LinuxOsTypeDebianCloud { $ControlPlaneVMBaseImageName }
        $LinuxOsTypeUbuntu { $ControlPlaneVMBaseUbuntuImageName }
        Default { throw "The Linux OS type '$linuxOsType' is not supported." }
    }
    return "$kubePath\bin\$fileName"
}

function Get-ControlPlaneVMRootfsPath {
    $linuxOsType = Get-LinuxOsType
    $fileName = switch ( $linuxOsType ) {
        $LinuxOsTypeDebianCloud { $ControlPlaneVMRootfsName }
        $LinuxOsTypeUbuntu { $ControlPlaneVMUbuntuRootfsName }
        Default { throw "The Linux OS type '$linuxOsType' is not supported." }
    }
    return "$kubePath\bin\$fileName"
}

<#
.SYNOPSIS
    Waits until a command can be executet via SSH on a remote machine.
.DESCRIPTION
    Waits until a command can be executet via SSH on a remote machine. Aborts the operation if a certain number of retries failed.
.PARAMETER User
    The user and IP of the remote machine, e.g. admin@192.168.0.11
.PARAMETER UserPwd
    The password for the remote user
.PARAMETER SshTestCommand
    The SSH test command to execute on the remote machine, e.g. 'whoami'
.PARAMETER ExpectedSshTestCommandResult
    The expected SSH test command result. DEFAULT: regex expression; with StrictEqualityCheck = $true: e.g. for command 'whoami' ==> 'my-machine\admin'
.PARAMETER StrictEqualityCheck
    If set, the SSH test command result will be checked with strict equality comparer (i.e. '-eq') instead of a regex expression match
.EXAMPLE
    Wait-ForSshPossible -User 'admin@192.168.0.11' -UserPwd 'my-secret' -SshTestCommand 'which curl' -ExpectedSshTestCommandResult '/bin/curl'
    ==> result will match the regex expression
.EXAMPLE
    Wait-ForSshPossible -User 'admin@192.168.0.11' -UserPwd 'my-secret' -SshTestCommand 'whoami' -ExpectedSshTestCommandResult 'my-machine\admin' -StrictEqualityCheck
    ==> result will be checked for strict equality, i.e. <result> -eq 'my-machine\admin'
#>
function Wait-ForSshPossible {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $User = $(throw 'Please specify the user and IP of the remote machine, e.g. admin@192.168.0.11'),
        [Parameter()]
        [string]$SshKey = '',
        [Parameter()]
        [string]$UserPwd = '',
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
    Write-Log "Performing SSH login into VM with $($User)..."
    while ($true) {
        $iteration++
        $result = ''

        if ($SshKey -ne '') {
            if ($Nested) {
                $result = ssh.exe -o StrictHostKeyChecking=no -i $SshKey $User "$($SshTestCommand)" 2>&1
            }
            else {
                $result = ssh.exe -n -o StrictHostKeyChecking=no -i $SshKey $User "$($SshTestCommand)" 2>&1
            }
        }
        else {
            $result = $(Write-Output yes | &"$plinkExe" -ssh -4 $User -pw $UserPwd -no-antispoof "$($SshTestCommand)" 2>&1)
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
            Write-Log "SSH login into VM with $($User) still not available, ssh result is '$($result)' aborting..." -Console
            throw "Unable to SSH login into VM"
        }
        if ($iteration -ge 3 ) {
            Write-Log "SSH login into VM with $($User) not yet possible, current result is '$($result)' waiting for it..."
        }
        Start-Sleep 4
    }
    if ($iteration -eq 1) {
        Write-Log "SSH login into VM with $($User) possible, no waiting needed."
    }
    else {
        Write-Log "SSH login into VM with $($User) now possible."
    }
}

<#
.SYNOPSIS
    Establishes first time connection with VM by accepting the key and retries until a command can be executet via SSH on a Linux machine.
.DESCRIPTION
    Waits until Initial connection command can be executed via SSH on a Linux machine.
.EXAMPLE
    Wait-ForSSHConnectionToLinuxVMViaPwd
#>
function Wait-ForSSHConnectionToLinuxVMViaPwd(
    [Parameter(Mandatory = $false)]
    [string]$User = $remoteUser,
    [Parameter(Mandatory = $false)]
    [string]$UserPwd = $remotePwd) {
    Write-Log "Initiating first time SSH login into VM with user $User"
    Wait-ForSshPossible -User $User -UserPwd $UserPwd -SshTestCommand 'which curl' -ExpectedSshTestCommandResult '/bin/curl'
}


<#
.SYNOPSIS
    Waits until a command can be executet via SSH on a Linux machine.
.DESCRIPTION
    Waits until a command can be executet via SSH on a Linux machine. Convenience wrapper around Wait-ForSshPossible.
.EXAMPLE
    Wait-ForSSHConnectionToLinuxVMViaSshKey
#>
function Wait-ForSSHConnectionToLinuxVMViaSshKey {
    Param(
        [Parameter(Mandatory = $false)]
        [string]$User = $remoteUser,
        [parameter(Mandatory = $false, HelpMessage = 'When executing ssh.exe in nested environment[host=>VM=>VM], -n flag should not be used.')]
        [switch] $Nested = $false
    )
    Wait-ForSshPossible -User $User -SshKey $key -SshTestCommand 'which curl' -ExpectedSshTestCommandResult '/bin/curl' -Nested:$Nested
}

function Get-DefaultUserNameControlPlane {
    return $defaultUserName
}

function Get-DefaultUserPwdControlPlane {
    return $remotePwd
}

function Get-DefaultUserNameWorkerNode {
    return $defaultUserName
}

function Get-DefaultUserPwdWorkerNode {
    return $remotePwd
}

<#
.SYNOPSIS
    Copies the Kube config file from master node to local machine.
.DESCRIPTION
    Copies the Kube config file from master node to local machine.
.EXAMPLE
    Copy-KubeConfigFromMasterNode
#>
function Copy-KubeConfigFromControlPlaneNode {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'When executing ssh.exe in nested environment[host=>VM=>VM], -n flag should not be used.')]
        [switch] $Nested = $false
    )

    # getting kube config from VM to windows host
    Write-Log "Retrieving kube config from master VM, writing to '$kubePath\config'"
    Remove-Item -Path "$kubePath\config" -Force -ErrorAction SilentlyContinue
    # checking cluster state
    $i = 0;
    while ($true) {
        $i++
        Write-Log "Handling loop for started cluster, checking kubeconfig availability (iteration $i):"
        Start-Sleep -s 3

        Write-Log 'Trying to get kube config from /etc/kubernetes/admin.conf'
        (Invoke-CmdOnControlPlaneViaSSHKey 'sudo cp /etc/kubernetes/admin.conf /home' -Nested:$Nested).Output | Write-Log
        Write-Log 'Trying to chmod file from /home/admin.conf'
        (Invoke-CmdOnControlPlaneViaSSHKey 'sudo chmod 775 /home/admin.conf' -Nested:$Nested).Output | Write-Log
        Write-Log 'Trying to scp file from /home/admin.conf'
        $source = '/home/admin.conf'
        Copy-FromControlPlaneViaSSHKey -Source $source -Target "$kubePath\config"
        if (Test-Path "$kubePath\config") {
            Write-Log "Kube config '$kubePath\config' successfully retrieved !"
            break;
        }
        Write-Log '... kube config not yet available.'
        if ($i -eq 25) {
            throw 'timeout, unable to find kubeconfig inside control plane, check the cluster availability'
        }
    }
}

function Get-ControlPlaneRemoteUser {
    return $remoteUser
}

Export-ModuleMember -Function Invoke-CmdOnControlPlaneViaSSHKey,
Invoke-CmdOnVmViaSSHKey,
Invoke-CmdOnControlPlaneViaUserAndPwd,
Get-IsControlPlaneRunning,
Copy-FromControlPlaneViaSSHKey,
Copy-FromRemoteComputerViaUserAndPwd,
Copy-ToControlPlaneViaSSHKey,
Copy-ToRemoteComputerViaSshKey,
Copy-ToControlPlaneViaUserAndPwd,
Copy-ToRemoteComputerViaUserAndPwd,
Test-ControlPlanePrerequisites,
Test-ExistingExternalSwitch,
Get-ControlPlaneVMBaseImagePath,
Get-ControlPlaneVMRootfsPath,
Wait-ForSSHConnectionToLinuxVMViaPwd,
Wait-ForSSHConnectionToLinuxVMViaSshKey,
Wait-ForSshPossible,
Get-DefaultUserNameControlPlane,
Get-DefaultUserPwdControlPlane,
Get-DefaultUserNameWorkerNode,
Get-DefaultUserPwdWorkerNode,
Copy-KubeConfigFromControlPlaneNode,
Get-ControlPlaneRemoteUser