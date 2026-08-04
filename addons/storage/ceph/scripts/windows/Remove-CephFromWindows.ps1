# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Removes the Ceph native Windows setup from the Windows worker node(s) of a K2s cluster.

.DESCRIPTION
Invoked by the storage/ceph addon Disable.ps1. Unmounts CephFS (stops/unregisters the startup task
and terminates ceph-dokan), deletes the Ceph mount directory, removes the Ceph client configuration,
and optionally uninstalls the native Ceph for Windows client plus Dokany. When invoked on the K2s
host, this script also dispatches the same cleanup to remote Windows worker VMs discovered from the
cluster so addon disable cleans up every Windows worker node consistently.

.PARAMETER RemoveClient
If set, also uninstalls the native Ceph for Windows client and Dokany. A reboot may be required
afterwards.

.PARAMETER LocalOnly
If set, only removes the local node state and does not attempt to discover or clean remote Windows
worker nodes. This is used when the script is copied to a remote worker VM for execution there.

.PARAMETER ShowLogs
If log output shall be streamed also to CLI output.
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Also uninstall the native Ceph client and Dokany')]
    [switch] $RemoveClient = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Only clean up the local node')]
    [switch] $LocalOnly = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)

$infraModule = "$PSScriptRoot/../../../../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$nodeModule = "$PSScriptRoot/../../../../../lib/modules/k2s/k2s.node.module/k2s.node.module.psm1"
$clusterConfigModule = "$PSScriptRoot/../../../../../lib/modules/k2s/k2s.infra.module/config/cluster.config.module.psm1"

if (-not $LocalOnly -and (Test-Path -Path $infraModule)) {
    Import-Module $infraModule, $clusterModule, $nodeModule, $clusterConfigModule
    Initialize-Logging -ShowLogs:$ShowLogs
}
else {
    if ((Test-Path -Path $infraModule) -and (-not (Get-Command -Name 'Write-Log' -ErrorAction SilentlyContinue))) {
        Import-Module $infraModule
        Initialize-Logging -ShowLogs:$ShowLogs
    }
    else {
        if (-not (Get-Command -Name 'Write-Log' -ErrorAction SilentlyContinue)) {
            function Write-Log { param([Parameter(ValueFromPipeline = $true)][string]$Message, [switch]$Console, [switch]$Error) process { Write-Output $Message } }
        }
        if (-not (Get-Command -Name 'Initialize-Logging' -ErrorAction SilentlyContinue)) {
            function Initialize-Logging { param([switch]$ShowLogs) }
        }
        Initialize-Logging -ShowLogs:$ShowLogs
    }
}

$cephProgramData = "$env:ProgramData\ceph"
$mountPoint = 'C:\ceph\data'
$mountRoot = Split-Path -Path $mountPoint -Parent
$cephInstallDir = Join-Path $env:ProgramFiles 'Ceph'
$dokanInstallDir = Join-Path $env:ProgramFiles 'Dokan'
$mountScript = "$PSScriptRoot\Mount-CephForWindows.ps1"

function Get-WindowsClusterNodes {
    $localHostName = "$env:COMPUTERNAME".Trim().ToLowerInvariant()

    $clusterNodesByName = @{}
    try {
        $clusterFilePath = Get-ClusterDescriptorFilePath
        if (Test-Path -Path $clusterFilePath) {
            $clusterJson = Get-JsonContent -FilePath $clusterFilePath
            if ($clusterJson -and $clusterJson.nodes) {
                foreach ($node in @($clusterJson.nodes)) {
                    if ("$($node.OS)".Trim().ToLowerInvariant() -eq 'windows') {
                        $clusterNodesByName["$($node.Name)".Trim().ToLowerInvariant()] = $node
                    }
                }
            }
        }
    }
    catch {
        Write-Log "[CephWin] WARNING: Could not read the cluster descriptor (cluster.json): $($_.Exception.Message)" -Console
    }

    $result = Invoke-Kubectl -Params 'get', 'nodes', '-l', 'kubernetes.io/os=windows', '-o', 'json'
    if ($result.Success -ne $true) {
        Write-Log "[CephWin] WARNING: Could not list Windows nodes via kubectl: $($result.Output)" -Console
        return @()
    }

    $parsed = $null
    try {
        $parsed = ($result.Output -join "`n") | ConvertFrom-Json
    }
    catch {
        Write-Log "[CephWin] WARNING: Could not parse 'kubectl get nodes' output: $($_.Exception.Message)" -Console
        return @()
    }

    if (-not $parsed -or -not $parsed.items) {
        return @()
    }

    return @(@($parsed.items) | ForEach-Object {
            $nodeName = "$($_.metadata.name)".Trim()
            $nodeKey = $nodeName.ToLowerInvariant()
            $clusterEntry = if ($clusterNodesByName.ContainsKey($nodeKey)) { $clusterNodesByName[$nodeKey] } else { $null }

            $isLocalHost = [string]::Equals($nodeKey, $localHostName, [System.StringComparison]::OrdinalIgnoreCase)
            $nodeType = if ($isLocalHost) { 'HOST' }
            elseif ($null -ne $clusterEntry -and -not [string]::IsNullOrWhiteSpace("$($clusterEntry.NodeType)")) { "$($clusterEntry.NodeType)".Trim() }
            else { 'VM-EXISTING' }

            $vmName = if ($null -ne $clusterEntry -and ($clusterEntry.PSObject.Properties.Name -contains 'VmName')) { "$($clusterEntry.VmName)".Trim() } else { '' }

            [pscustomobject]@{
                Name     = $nodeName
                NodeType = $nodeType
                VmName   = $vmName
            }
        })
}

function Remove-DirectoryIfPresent {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if (-not (Test-Path -Path $Path)) {
        return
    }

    try {
        Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
        Write-Log "[CephWin] Removed $Description at '$Path'." -Console
    }
    catch {
        Write-Log "[CephWin] WARNING: Could not remove $Description at '$Path': $($_.Exception.Message)" -Console
    }
}

function Remove-EmptyDirectoryIfPresent {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -Path $Path)) {
        return
    }

    try {
        $children = @(Get-ChildItem -Path $Path -Force -ErrorAction Stop)
        if ($children.Count -eq 0) {
            Remove-Item -Path $Path -Force -ErrorAction Stop
            Write-Log "[CephWin] Removed empty directory '$Path'." -Console
        }
    }
    catch {
        Write-Log "[CephWin] WARNING: Could not remove empty directory '$Path': $($_.Exception.Message)" -Console
    }
}

function Get-RegisteredWindowsProducts {
    $uninstallRoots = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $products = @()
    foreach ($root in $uninstallRoots) {
        $entries = @(Get-ItemProperty -Path $root -ErrorAction SilentlyContinue)
        foreach ($entry in $entries) {
            $displayName = "$($entry.DisplayName)".Trim()
            if ([string]::IsNullOrWhiteSpace($displayName)) {
                continue
            }

            $products += [pscustomobject]@{
                DisplayName          = $displayName
                QuietUninstallString = "$($entry.QuietUninstallString)".Trim()
                UninstallString      = "$($entry.UninstallString)".Trim()
                ProductCode          = if ($entry.PSChildName -match '^\{[0-9A-Fa-f-]+\}$') { $entry.PSChildName } else { '' }
            }
        }
    }

    return $products
}

function Invoke-RegisteredProductUninstall {
    param(
        [Parameter(Mandatory = $true)][string]$NameRegex,
        [Parameter(Mandatory = $true)][string]$DisplayLabel
    )

    $product = @(Get-RegisteredWindowsProducts | Where-Object { $_.DisplayName -match $NameRegex } | Select-Object -First 1)
    if ($product.Count -eq 0) {
        Write-Log "[CephWin] $DisplayLabel is not registered in Windows uninstall entries; skipping MSI uninstall." -Console
        return
    }

    $target = $product[0]
    Write-Log "[CephWin] Uninstalling '$($target.DisplayName)'" -Console

    $process = $null
    if (-not [string]::IsNullOrWhiteSpace($target.ProductCode)) {
        $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/x', $target.ProductCode, '/qn', '/norestart') -Wait -PassThru -NoNewWindow
    }
    else {
        $commandText = if (-not [string]::IsNullOrWhiteSpace($target.QuietUninstallString)) { $target.QuietUninstallString } else { $target.UninstallString }
        if ([string]::IsNullOrWhiteSpace($commandText)) {
            Write-Log "[CephWin] WARNING: '$($target.DisplayName)' has no uninstall command registered; skipping MSI uninstall." -Console
            return
        }

        if ($commandText -match '(?i)msiexec(\.exe)?') {
            $productCodeMatch = [regex]::Match($commandText, '\{[0-9A-Fa-f-]+\}')
            if ($productCodeMatch.Success) {
                $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/x', $productCodeMatch.Value, '/qn', '/norestart') -Wait -PassThru -NoNewWindow
            }
        }

        if ($null -eq $process) {
            $process = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $commandText) -Wait -PassThru -NoNewWindow
        }
    }

    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        Write-Log "[CephWin] WARNING: Uninstall of '$($target.DisplayName)' returned exit code $($process.ExitCode)." -Console
    }
    elseif ($process.ExitCode -eq 3010) {
        Write-Log "[CephWin] '$($target.DisplayName)' uninstalled; a reboot is required to complete cleanup." -Console
    }
    else {
        Write-Log "[CephWin] '$($target.DisplayName)' uninstalled successfully." -Console
    }
}

function Remove-LocalWindowsCephSetup {
    Write-Log '[CephWin] Unmounting CephFS and removing the startup task' -Console

    if (Test-Path -Path $mountScript) {
        & $mountScript -Unmount -ShowLogs:$ShowLogs
        if ($LASTEXITCODE -ne 0) {
            Write-Log "[CephWin] WARNING: CephFS unmount reported a problem (exit code $LASTEXITCODE); continuing with cleanup." -Console
        }
    }

    Remove-DirectoryIfPresent -Path $mountPoint -Description 'Ceph mount directory'
    Remove-EmptyDirectoryIfPresent -Path $mountRoot

    if (Test-Path -Path $cephProgramData) {
        Write-Log "[CephWin] Removing Ceph client configuration from $cephProgramData" -Console
        Remove-DirectoryIfPresent -Path $cephProgramData -Description 'Ceph program data'
    }

    if ($RemoveClient) {
        Write-Log '[CephWin] Uninstalling the native Ceph for Windows client (a reboot may be required for the WNBD driver).' -Console
        Invoke-RegisteredProductUninstall -NameRegex '(?i)\bceph\b' -DisplayLabel 'Ceph for Windows'
        Invoke-RegisteredProductUninstall -NameRegex '(?i)\bdokan\b' -DisplayLabel 'Dokany'

        Remove-DirectoryIfPresent -Path $cephInstallDir -Description 'Ceph install directory'
        Remove-DirectoryIfPresent -Path $dokanInstallDir -Description 'Dokan install directory'
    }
}

function Invoke-RemoteWindowsNodeCleanup {
    param([Parameter(Mandatory = $true)][pscustomobject]$WindowsNode)

    $nodeName = "$($WindowsNode.Name)".Trim()
    $vmName = "$($WindowsNode.VmName)".Trim()

    if ([string]::IsNullOrWhiteSpace($vmName)) {
        Write-Log "[CephWin] WARNING: Windows node '$nodeName' has no VmName in cluster.json; cannot open a remote session for cleanup. Run Remove-CephFromWindows.ps1 manually on that node." -Console
        return $false
    }

    $session = $null
    try {
        Write-Log "[CephWin] Opening remote session to Windows node '$nodeName' (VM '$vmName') for cleanup." -Console
        $session = Open-RemoteSession -VmName $vmName -VmPwd (Get-DefaultTempPwd) -NoLog

        $remoteDir = Invoke-Command -Session $session -ScriptBlock {
            $dir = Join-Path $env:TEMP ('k2s-ceph-remove-' + [guid]::NewGuid().ToString())
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
            return $dir
        }

        Copy-Item -Path $PSCommandPath -Destination (Join-Path $remoteDir 'Remove-CephFromWindows.ps1') -ToSession $session -Force
        if (Test-Path -Path $mountScript) {
            Copy-Item -Path $mountScript -Destination (Join-Path $remoteDir 'Mount-CephForWindows.ps1') -ToSession $session -Force
        }

        $remoteExit = Invoke-Command -Session $session -ArgumentList $remoteDir, $RemoveClient.IsPresent -ScriptBlock {
            param($dir, $removeClientFlag)

            $script = Join-Path $dir 'Remove-CephFromWindows.ps1'
            & $script -RemoveClient:([bool]$removeClientFlag) -LocalOnly

            $code = $LASTEXITCODE
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
            return $code
        }

        if ($remoteExit -ne 0) {
            Write-Log "[CephWin] WARNING: Remote cleanup on Windows node '$nodeName' returned exit code $remoteExit." -Console
            return $false
        }

        Write-Log "[CephWin] Remote cleanup completed on Windows node '$nodeName'." -Console
        return $true
    }
    catch {
        Write-Log "[CephWin] WARNING: Remote cleanup on Windows node '$nodeName' failed: $($_.Exception.Message)" -Console
        return $false
    }
    finally {
        if ($null -ne $session) {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
    }
}

Remove-LocalWindowsCephSetup

if (-not $LocalOnly) {
    $windowsNodes = Get-WindowsClusterNodes
    foreach ($windowsNode in $windowsNodes) {
        if ([string]::Equals("$($windowsNode.NodeType)".Trim(), 'HOST', [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $null = Invoke-RemoteWindowsNodeCleanup -WindowsNode $windowsNode
    }
}

Write-Log '[CephWin] Windows Ceph native setup removal completed.' -Console
exit 0
