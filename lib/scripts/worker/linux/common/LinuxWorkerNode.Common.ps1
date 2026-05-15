# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

function Import-LinuxWorkerScriptModules {
    Param(
        [switch] $IncludeAddons = $false,
        [switch] $IncludePuttyTools = $false
    )

    $infraModule =   "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
    $nodeModule =    "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
    $clusterModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"

    $modulePaths = @($infraModule, $nodeModule, $clusterModule)
    if ($IncludeAddons) {
        $addonsModule = "$PSScriptRoot\..\..\..\..\..\addons\addons.module.psm1"
        $modulePaths += $addonsModule
    }

    Import-Module $modulePaths

    if ($IncludePuttyTools) {
        $puttyToolsHelper = "$PSScriptRoot\..\..\..\k2s\system\package\New-K2sPackage.PuttyTools.ps1"
        . $puttyToolsHelper
    }
}

function Initialize-LinuxWorkerScriptEnvironment {
    Param(
        [switch] $ShowLogs = $false,
        [switch] $IncludeAddons = $false,
        [switch] $IncludePuttyTools = $false
    )

    Import-LinuxWorkerScriptModules -IncludeAddons:$IncludeAddons -IncludePuttyTools:$IncludePuttyTools
    Initialize-Logging -ShowLogs:$ShowLogs

    $installationPath = Get-KubePath
    Set-Location $installationPath
    $ProgressPreference = 'SilentlyContinue'
}

function Assert-LinuxWorkerPuttyToolsReady {
    Param(
        [string] $LogPrefix = '[NodeAdd]',
        [string] $Proxy = ''
    )

    $puttyToolsHelper = "$PSScriptRoot\..\..\..\k2s\system\package\New-K2sPackage.PuttyTools.ps1"
    . $puttyToolsHelper

    Assert-PuttyToolsReady -LogPrefix $LogPrefix -Proxy $Proxy
}

function Assert-LinuxWorkerNodeSshConnectivity {
    Param(
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $LogPrefix = '[NodeAdd]',
        [string] $TargetDescription = 'node'
    )

    $connectionCheck = Invoke-CmdOnVmViaSSHKey -CmdToExecute 'which ls' -UserName $UserName -IpAddress $IpAddress
    if (!$connectionCheck.Success) {
        throw "$LogPrefix Cannot connect to $TargetDescription with IP '$IpAddress'. Error: $($connectionCheck.Output)"
    }
}

function Assert-LinuxWorkerNodeAuthorizedKey {
    Param(
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $LogPrefix = '[NodeAdd]'
    )

    $localPublicKeyFilePath = "$(Get-SSHKeyControlPlane).pub"
    if (!(Test-Path -Path $localPublicKeyFilePath)) {
        throw "$LogPrefix Precondition not met: SSH public key file '$localPublicKeyFilePath' must exist."
    }
    $localPublicKey = (Get-Content -Raw $localPublicKeyFilePath).Trim()
    if ([string]::IsNullOrWhiteSpace($localPublicKey)) {
        throw "$LogPrefix Precondition not met: SSH public key file '$localPublicKeyFilePath' is empty."
    }

    $authorizedKeysFilePath = '~/.ssh/authorized_keys'
    $authorizedKeysRaw = (Invoke-CmdOnVmViaSSHKey -CmdToExecute "[ -f $authorizedKeysFilePath ] && cat $authorizedKeysFilePath || echo 'File $authorizedKeysFilePath not available'" -UserName $UserName -IpAddress $IpAddress).Output
    $authorizedKeys = if ($authorizedKeysRaw -is [array]) { $authorizedKeysRaw -join "`n" } else { [string]$authorizedKeysRaw }
    $authorizedKeys = $authorizedKeys.Replace("`r", '')
    $normalizedLocalPublicKey = $localPublicKey.Replace("`r", '')
    if (!($authorizedKeys.Contains($normalizedLocalPublicKey))) {
        throw "$LogPrefix Precondition not met: the K2s public key from '$localPublicKeyFilePath' is NOT in '$authorizedKeysFilePath' on the remote machine at $IpAddress. Please add it manually."
    }
}


function Get-LinuxWorkerNodeProvisioningContext {
    Param(
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $NodeName = '',
        [string] $LogPrefix = '[NodeAdd]',
        [string] $TargetDescription = 'remote computer'
    )

    $actualHostname = (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'echo $(hostname)' -UserName $UserName -IpAddress $IpAddress).Output
    $k8sFormattedNodeName = $actualHostname.ToLower()

    if (![string]::IsNullOrWhiteSpace($NodeName) -and ($NodeName.ToLower() -ne $k8sFormattedNodeName)) {
        throw "$LogPrefix Precondition not met: the passed NodeName '$NodeName' does not match the hostname '$actualHostname' of the $TargetDescription with IP '$IpAddress'."
    }

    $installedDistribution = Get-InstalledDistribution -UserName $UserName -IpAddress $IpAddress
    $osMessage = "{0} Detected OS on {1}: {2}" -f $LogPrefix, $TargetDescription, $installedDistribution
    Write-Log $osMessage -Console
    Test-SupportedWorkerOS -OS $installedDistribution

    $clusterState = (Invoke-Kubectl -Params @('get', 'nodes', '-o', 'wide')).Output
    if ($clusterState -match $k8sFormattedNodeName) {
        throw "$LogPrefix Precondition not met: node '$k8sFormattedNodeName' is already part of the cluster."
    }

    [PSCustomObject]@{
        ActualHostname         = $actualHostname
        KubernetesNodeName     = $k8sFormattedNodeName
        InstalledDistribution  = $installedDistribution
    }
}

function Disable-LinuxWorkerNodeSwap {
    Param(
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $LogPrefix = '[NodeAdd]'
    )

    Write-Log "$LogPrefix Disabling swap on remote node at $IpAddress" -Console
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo swapon --show' -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute "swapFiles=`$(cat /proc/swaps | awk 'NR>1 {print `$1}')" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo swapoff -a' -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute "for swapFile in `$swapFiles; do sudo rm '`$swapFile'; done" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo sed -i '/\sswap\s/d' /etc/fstab" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo swapon --show' -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
    Write-Log "$LogPrefix Swap disabled successfully" -Console
}