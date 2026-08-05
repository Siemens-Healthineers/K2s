# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Removes the Ceph native Windows setup from the Windows worker node(s) of a K2s cluster.

.DESCRIPTION
Invoked by the storage/ceph addon Disable.ps1. Unmounts CephFS (stops/unregisters the startup task
and terminates ceph-dokan), deletes the Ceph mount directory, and removes the Ceph client
configuration. When invoked on the K2s host, this script also dispatches the same cleanup to remote
Windows worker VMs discovered from the cluster so addon disable cleans up every Windows worker node
consistently.

The native 'Ceph for Windows' and 'Dokany' packages are intentionally NEVER uninstalled: the Ceph
MSI bundles a shared Microsoft Visual C++ runtime that the Windows shell depends on, and Dokany
installs the shared 'dokan2.sys' driver used by unrelated software. Uninstalling either can leave the
host without a usable desktop, so K2s removes only its own configuration and mount.

.PARAMETER LocalOnly
If set, only removes the local node state and does not attempt to discover or clean remote Windows
worker nodes. This is used when the script is copied to a remote worker VM for execution there.

.PARAMETER ShowLogs
If log output shall be streamed also to CLI output.
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'CephFS mount point to remove')]
    [string] $MountPoint = 'C:\k8s-ceph-share',
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
$mountRoot = Split-Path -Path $mountPoint -Parent
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

    # Retry a few times: a just-released Dokany mount point or a file handle held by a terminating
    # process can briefly keep the directory locked immediately after unmount.
    $lastError = $null
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            Write-Log "[CephWin] Removed $Description at '$Path'." -Console
            return
        }
        catch {
            $lastError = $_
            Start-Sleep -Milliseconds 500
        }
    }

    Write-Log "[CephWin] WARNING: Could not remove $Description at '$Path': $($lastError.Exception.Message)" -Console
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

function Wait-CephFsMountReleased {
    # After Remove-CephFsMount stops the scheduled task and force-terminates ceph-dokan, the Dokany
    # device takes a moment to detach. The mount-point directory must only be removed once no
    # ceph-dokan process remains: otherwise Remove-Item would either fail (device still in use) or
    # recurse into the still-live CephFS mount and delete cluster data. Returns $true when released.
    for ($i = 0; $i -lt 15; $i++) {
        if ($null -eq (Get-Process -Name 'ceph-dokan' -ErrorAction SilentlyContinue)) {
            return $true
        }
        Start-Sleep -Seconds 1
    }
    return ($null -eq (Get-Process -Name 'ceph-dokan' -ErrorAction SilentlyContinue))
}

function Remove-LocalWindowsCephSetup {
    Write-Log '[CephWin] Unmounting CephFS and removing the startup task' -Console

    if (Test-Path -Path $mountScript) {
        & $mountScript -Unmount -MountPoint $mountPoint -ShowLogs:$ShowLogs
        if ($LASTEXITCODE -ne 0) {
            Write-Log "[CephWin] WARNING: CephFS unmount reported a problem (exit code $LASTEXITCODE); continuing with cleanup." -Console
        }
    }

    # The mount directory is created as part of the Ceph setup, so remove it on disable. Wait for the
    # Dokany mount to be fully released first so we never delete through a still-live CephFS mount or
    # fail on a busy device. A single drive-letter mount point (e.g. 'X:') has no directory to remove.
    $isDriveLetterMount = ($mountPoint -match '^[A-Za-z]:?$')
    if (-not $isDriveLetterMount) {
        if (Wait-CephFsMountReleased) {
            Remove-DirectoryIfPresent -Path $mountPoint -Description 'Ceph mount directory'
            if (-not [string]::IsNullOrWhiteSpace($mountRoot) -and ($mountRoot.TrimEnd('\\') -notmatch '^[A-Za-z]:$')) {
                Remove-EmptyDirectoryIfPresent -Path $mountRoot
            }
        }
        else {
            Write-Log "[CephWin] WARNING: ceph-dokan is still running; skipping removal of the mount directory '$mountPoint' to avoid deleting through a live CephFS mount. Remove it manually once the mount is released." -Console
        }
    }

    if (Test-Path -Path $cephProgramData) {
        Write-Log "[CephWin] Removing Ceph client configuration from $cephProgramData" -Console
        Remove-DirectoryIfPresent -Path $cephProgramData -Description 'Ceph program data'
    }

    Write-Log "[CephWin] Native 'Ceph for Windows' and 'Dokany' packages are intentionally not auto-uninstalled. If you are certain nothing else on this machine needs them, uninstall 'Ceph for Windows' and 'Dokan Library' manually via Windows 'Apps & features' and reboot." -Console
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

        $remoteExit = Invoke-Command -Session $session -ArgumentList $remoteDir, $MountPoint -ScriptBlock {
            param($dir, $mountPoint)

            $script = Join-Path $dir 'Remove-CephFromWindows.ps1'
            & $script -MountPoint $mountPoint -LocalOnly

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
