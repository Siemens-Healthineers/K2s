# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

$configModule = "$PSScriptRoot\..\..\..\k2s.infra.module\config\config.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\k2s.infra.module\log\log.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\k2s.infra.module\path\path.module.psm1"
Import-Module $configModule, $pathModule, $logModule

$ipControlPlane = Get-ConfiguredIPControlPlane
$nameControlPlane = Get-ConfigControlPlaneNodeHostname
$defaultUserName = "remote"
$remoteUser = "$defaultUserName@$ipControlPlane"
$remotePwd = "admin"
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
    [Parameter(Mandatory = $false ,HelpMessage = 'When executing ssh.exe in nested environment[host=>VM=>VM], -n flag should not be used.')]
    [switch]$Nested = $false)
{

    if (!$NoLog) {
        Write-Log "cmd: $CmdToExecute, retries: $Retries, timeout: $Timeout sec, ignore err: $IgnoreErrors, nested: $Nested"
    }
    $Stoploop = $false
    [uint16]$Retrycount = 1
    do {
        try {

            if ($Nested) {
                ssh.exe -o StrictHostKeyChecking=no -i $key $remoteUser $CmdToExecute 2>&1 | ForEach-Object { Write-Log $_ -Console -Raw }
            }
            else {
                ssh.exe -n -o StrictHostKeyChecking=no -i $key $remoteUser $CmdToExecute 2>&1 | ForEach-Object { Write-Log $_ -Console -Raw }
            }

            if ($LASTEXITCODE -ne 0 -and !$IgnoreErrors) { throw "Error occurred while executing command '$CmdToExecute' in control plane (exit code: '$LASTEXITCODE')" }
            $Stoploop = $true
        }
        catch {
            Write-Log $_
            if ($Retrycount -gt $Retries) {
                $Stoploop = $true
            }
            else {
                Write-Log "cmd: $CmdToExecute will be retried.."
                Start-Sleep -Seconds $Timeout
                $Retrycount = $Retrycount + 1
            }
        }
    }
    While ($Stoploop -eq $false)
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
    [string]$RepairCmd = $null){

    if (!$NoLog) {
        Write-Log "cmd: $CmdToExecute, retries: $Retries, timeout: $Timeout sec, ignore err: $IgnoreErrors"
    }
    $Stoploop = $false
    [uint16]$Retrycount = 1
    do {
        try {
            &"$plinkExe" -ssh -4 $RemoteUser -pw $RemoteUserPwd -no-antispoof $CmdToExecute 2>&1 | ForEach-Object { Write-Log $_ -Console -Raw }
            if ($LASTEXITCODE -ne 0 -and !$IgnoreErrors) { throw "Error occurred while executing command '$CmdToExecute' (exit code: '$LASTEXITCODE')" }
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
                if( ($null -ne $RepairCmd) -and !$IgnoreErrors) {
                    Write-Log "Executing repair cmd: $RepairCmd"
                    &"$plinkExe" -ssh -4 $RemoteUser -pw $RemoteUserPwd -no-antispoof $RepairCmd 2>&1 | ForEach-Object { Write-Log $_ -Console -Raw }
                }
                
                Start-Sleep -Seconds $Timeout
                $Retrycount = $Retrycount + 1
            }
        }
    }
    While ($Stoploop -eq $false)
}

function Invoke-TerminalOnControlPanelViaSSHKey {
    Write-Log "Invoking ssh terminal on Control Plane VM."
    ssh.exe -o StrictHostKeyChecking=no -i $key $remoteUser
}

function Get-IsControlPlaneRunning {
    $masterVmState = (Get-VM -Name $nameControlPlane).State
    return $masterVmState -eq [Microsoft.HyperV.PowerShell.VMState]::Running
}

function Copy-FromControlPlaneViaSSHKey($Source, $Target,
    [Parameter(Mandatory = $false)]
    [switch]$IgnoreErrors = $false) {
    Write-Log "copy: $Source to: $Target IgnoreErrors: $IgnoreErrors"
    $error.Clear()
    scp.exe -o StrictHostKeyChecking=no -r -i $key "${remoteUser}:$Source" "$Target" 2>&1 | ForEach-Object { "$_" }

    if ($error.count -gt 0 -and !$IgnoreErrors) { throw "Executing $CmdToExecute failed! " + $error }
}

function Copy-FromControlPlaneViaUserAndPwd($Source, $Target,
    [Parameter(Mandatory = $false)]
    [switch]$IgnoreErrors = $false) {
    Write-Log "copy: $Source to: $Target IgnoreErrors: $IgnoreErrors"
    $error.Clear()
    echo yes | &"$scpExe" -ssh -4 -q -r -pw $remotePwd "${remoteUser}:$Source" "$Target" 2>&1 | ForEach-Object { "$_" }

    if ($error.count -gt 0 -and !$IgnoreErrors) { throw "Executing $CmdToExecute failed! " + $error }
}

function Copy-ToControlPlaneViaSSHKey($Source, $Target,
    [Parameter(Mandatory = $false)]
    [switch]$IgnoreErrors = $false) {
    Write-Log "copy: $Source to: $Target IgnoreErrors: $IgnoreErrors"
    $error.Clear()
    scp.exe -o StrictHostKeyChecking=no -r -i $key "$Source" "${remoteUser}:$Target" 2>&1 | ForEach-Object { "$_" }

    if ($error.count -gt 0 -and !$IgnoreErrors) { throw "Executing $CmdToExecute failed! " + $error }
}

function Copy-ToControlPlaneViaUserAndPwd($Source, $Target,
    [Parameter(Mandatory = $false)]
    [switch]$IgnoreErrors = $false) {
    Write-Log "copy: $Source to: $Target IgnoreErrors: $IgnoreErrors"
    $error.Clear()
    echo yes | &"$scpExe" -ssh -4 -q -r -pw $remotePwd "$Source" "${remoteUser}:$Target" 2>&1 | ForEach-Object { "$_" }

    if ($error.count -gt 0 -and !$IgnoreErrors) { throw "Executing $CmdToExecute failed! " + $error }
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
        Write-Log 'SmallSetup needs minimal 2GB main memory, you have passed a lower value!'
        throw 'Memory passed to low'
    }

    # check disk
    $defaultProvisioningBaseImageSize = Get-DefaultProvisioningBaseImageDiskSize
    if ( $MasterDiskSize -lt $defaultProvisioningBaseImageSize ) {
        Write-Log "SmallSetup needs minimal $defaultProvisioningBaseImageSize disk space, you have passed a lower value!"
        throw 'Disk size passed to low'
    }

    #Check for running VMs and minikube
    $runningVMs = Get-VM -ErrorAction SilentlyContinue | Where-Object { $_.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running }
    if ($runningVMs) {
        Write-Log 'Active Hyper-V VM:'
        Write-Log $($runningVMs | Select-Object -Property Name)
        if ($runningVMs | Where-Object Name -eq 'minikube') {
            throw "Minikube must be stopped before running the installer, do 'minikube stop'"
        }
    }

    if (Get-VM -ErrorAction SilentlyContinue -Name $nameControlPlane) {
        throw "$nameControlPlane VM must not exist before installation, please perform k2s uninstall"
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
            $result = $(echo yes | &"$plinkExe" -ssh -4 $User -pw $UserPwd -no-antispoof "$($SshTestCommand)" 2>&1)
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
            Write-Log "SSH login into VM with $($User) still not available, aborting..."
            throw "Unable to login into VM with $($User)"
        }
        if ($iteration -ge 3 ) {
            Write-Log "SSH login into VM with $($User) not yet possible, waiting for it..."
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
    Waits until Initial connection command can be executet via SSH on a Linux machine.
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
        [parameter(Mandatory = $false, HelpMessage = 'When executing ssh.exe in nested environment[host=>VM=>VM], -n flag should not be used.')]
        [switch] $Nested = $false
    )

    Wait-ForSshPossible -User $remoteUser -SshKey $key -SshTestCommand 'which curl' -ExpectedSshTestCommandResult '/bin/curl' -Nested:$Nested
}

function Get-DefaultUserNameControlPlane {
    return $defaultUserName
}

function Get-DefaultUserPwdControlPlane {
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
        Invoke-CmdOnControlPlaneViaSSHKey 'sudo cp /etc/kubernetes/admin.conf /home' -Nested:$Nested
        Write-Log 'Trying to chmod file from /home/admin.conf'
        Invoke-CmdOnControlPlaneViaSSHKey 'sudo chmod 775 /home/admin.conf' -Nested:$Nested
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

Export-ModuleMember -Function Invoke-CmdOnControlPlaneViaSSHKey,
Invoke-CmdOnControlPlaneViaUserAndPwd,
Invoke-TerminalOnControlPanelViaSSHKey,
Get-IsControlPlaneRunning,
Copy-FromControlPlaneViaSSHKey,
Copy-FromControlPlaneViaUserAndPwd,
Copy-ToControlPlaneViaSSHKey,
Copy-ToControlPlaneViaUserAndPwd,
Test-ControlPlanePrerequisites,
Get-LinuxOsType,
Get-IsLinuxOsDebian,
Get-ControlPlaneVMBaseImagePath,
Get-ControlPlaneVMRootfsPath,
Wait-ForSSHConnectionToLinuxVMViaPwd,
Wait-ForSSHConnectionToLinuxVMViaSshKey,
Wait-ForSshPossible,
Get-DefaultUserNameControlPlane,
Get-DefaultUserPwdControlPlane,
Copy-KubeConfigFromControlPlaneNode