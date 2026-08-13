# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Deploys the Ceph node plugin to the Windows worker node(s) of a K2s cluster.

.DESCRIPTION
Invoked by the storage/ceph addon Enable.ps1 after the Ceph cluster has been provisioned and the
Linux CSI components are ready. On Linux the ceph-csi-operator reconciles the CephFS node plugin
automatically; Windows nodes are not managed by the operator. This script therefore:
  1. discovers the Windows worker node(s) from the Kubernetes API ('kubectl get nodes', label
     'kubernetes.io/os=windows') and enriches them from the cluster descriptor (cluster.json): the
     local K2s host is the Windows worker node ('HOST'); an added external node ('VM-EXISTING') is a
     Hyper-V worker VM, and
  2. installs and configures the native Ceph client on each Windows node (WNBD + ceph-dokan) via
     Install-CephForWindows.ps1 — locally on the HOST node and remotely (over a PowerShell remoting
     session) on VM-EXISTING nodes — using the connection details of the freshly provisioned cluster, and
  3. mounts the CephFS filesystem (via ceph-dokan) and registers a startup task on each node using
     Mount-CephForWindows.ps1, so Windows pods can consume the Ceph storage through a hostPath volume.

Ceph on Windows does NOT use a containerized CSI node plugin: there is no upstream Windows cephcsi
image, and CephFS/RBD volumes are mounted natively through the host-installed Ceph client. No
DaemonSet or Kubernetes manifests are applied for Windows nodes.

See https://docs.ceph.com/en/latest/install/windows-install/ for the underlying Windows client
prerequisites (WNBD driver, Dokany 2.0.5+, ceph.conf and keyring).

.PARAMETER Config
The parsed ceph-config.json object. After New-CephCluster.ps1 has run it also carries the actual
connection details of the provisioned cluster (monitorEndpoints, cephKey, clusterId, cephUser).

.PARAMETER ShowLogs
If log output shall be streamed also to CLI output.
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Parsed ceph-config.json object')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)

$infraModule = "$PSScriptRoot/../../../../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$nodeModule = "$PSScriptRoot/../../../../../lib/modules/k2s/k2s.node.module/k2s.node.module.psm1"
$clusterConfigModule = "$PSScriptRoot/../../../../../lib/modules/k2s/k2s.infra.module/config/cluster.config.module.psm1"
$proxyModule = "$PSScriptRoot/../../../../../lib/modules/k2s/k2s.node.module/windowsnode/proxy/proxy.module.psm1"
Import-Module $infraModule, $clusterModule, $nodeModule, $clusterConfigModule, $proxyModule
Initialize-Logging -ShowLogs:$ShowLogs

$installScript = "$PSScriptRoot\Install-CephForWindows.ps1"
$mountScript = "$PSScriptRoot\Mount-CephForWindows.ps1"
$stagedMsiDir = "$PSScriptRoot\..\..\bin\windows"
$storageAddonManifestPath = "$PSScriptRoot\..\..\..\addon.manifest.yaml"

<#
.SYNOPSIS
Returns the Windows worker nodes of the K2s cluster.

.DESCRIPTION
Windows worker nodes are discovered from the Kubernetes API (nodes labeled 'kubernetes.io/os=windows')
so that every Windows node that has actually joined the cluster is covered. Each discovered node is
then enriched with the matching entry from the K2s cluster descriptor (cluster.json) to determine how
it must be reached for the native client installation:
  - the node whose name matches the local host is the K2s HOST Windows worker node (installed locally);
  - a node that also appears in cluster.json as an added external node (NodeType 'VM-EXISTING') is a
    Hyper-V worker VM (installed remotely via a PowerShell remoting session using its VmName);
  - a node that is neither the local host nor present in cluster.json is reported without connection
    details so the caller can surface an actionable message.
#>
function Get-WindowsClusterNodes {
    $localHostName = "$env:COMPUTERNAME".Trim().ToLowerInvariant()

    # Build a lookup of the Windows nodes declared in cluster.json (added external nodes).
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
            $ipAddress = if ($null -ne $clusterEntry -and ($clusterEntry.PSObject.Properties.Name -contains 'IpAddress')) { "$($clusterEntry.IpAddress)".Trim() } else { '' }

            [pscustomobject]@{
                Name       = $nodeName
                NodeType   = $nodeType
                VmName     = $vmName
                IpAddress  = $ipAddress
                InCluster  = ($null -ne $clusterEntry)
            }
        })
}

<#
.SYNOPSIS
Resolves the Ceph connection details required by the Windows client from the addon config.
#>
function Get-CephConnectionFromConfig {
    param([pscustomobject]$Config)

    if ($null -eq $Config) {
        throw 'No Ceph configuration was provided; cannot resolve connection details for the Windows client.'
    }

    $monitorEndpoints = if ($Config.PSObject.Properties.Name -contains 'monitorEndpoints') { "$($Config.monitorEndpoints)".Trim() } else { '' }
    $adminKey = if ($Config.PSObject.Properties.Name -contains 'cephKey') { "$($Config.cephKey)".Trim() } else { '' }
    $clusterId = if ($Config.PSObject.Properties.Name -contains 'clusterId') { "$($Config.clusterId)".Trim() } else { '' }
    $cephUser = if ($Config.PSObject.Properties.Name -contains 'cephUser') { "$($Config.cephUser)".Trim() } else { 'client.admin' }

    if ([string]::IsNullOrWhiteSpace($monitorEndpoints)) { throw "Ceph monitor endpoints are missing; cannot configure the Windows client." }
    if ([string]::IsNullOrWhiteSpace($adminKey)) { throw "Ceph admin key is missing; cannot configure the Windows client." }
    if ([string]::IsNullOrWhiteSpace($clusterId)) { throw "Ceph cluster id (fsid) is missing; cannot configure the Windows client." }
    if ([string]::IsNullOrWhiteSpace($cephUser)) { $cephUser = 'client.admin' }

    $cephFsName = if ($Config.PSObject.Properties.Name -contains 'cephfsFilesystem') { "$($Config.cephfsFilesystem)".Trim() } else { '' }

    return [pscustomobject]@{
        MonitorEndpoints = $monitorEndpoints
        AdminKey         = $adminKey
        ClusterId        = $clusterId
        CephUser         = $cephUser
        CephFsName       = $cephFsName
    }
}

function Get-WindowsCephMountPoint {
    param([pscustomobject]$Config)

    $defaultMountPoint = 'C:\k8s-ceph-share'
    if ($null -eq $Config) {
        return $defaultMountPoint
    }

    if (($Config.PSObject.Properties.Name -contains 'winMountPath') -and -not [string]::IsNullOrWhiteSpace("$($Config.winMountPath)")) {
        return "$($Config.winMountPath)".Trim()
    }

    return $defaultMountPoint
}

<#
.SYNOPSIS
Resolves a staged MSI path (for offline install) or a download URL (for online install).
#>
function Resolve-WindowsMsiSettings {
    param([pscustomobject]$Config)

    $cephMsiUrl = ''
    $dokanyMsiUrl = ''
    $cephMsiDestination = ''
    $dokanyMsiDestination = ''

    function Resolve-StagedMsiPath {
        param(
            [string]$DisplayName,
            [string]$ManifestDestination,
            [string]$FallbackPattern
        )

        if (-not (Test-Path -Path $stagedMsiDir)) {
            return ''
        }

        if (-not [string]::IsNullOrWhiteSpace($ManifestDestination)) {
            $expectedFileName = Split-Path -Path $ManifestDestination -Leaf
            if (-not [string]::IsNullOrWhiteSpace($expectedFileName)) {
                $exactPath = Join-Path $stagedMsiDir $expectedFileName
                if (Test-Path -Path $exactPath) {
                    Write-Log "[CephWin] Using staged $DisplayName MSI from manifest destination filename: $expectedFileName" -Console
                    return $exactPath
                }
            }
        }

        $matches = @(Get-ChildItem -Path $stagedMsiDir -Filter $FallbackPattern -File -ErrorAction SilentlyContinue | Sort-Object -Property Name)
        if ($matches.Count -eq 0) {
            return ''
        }

        if ($matches.Count -gt 1) {
            Write-Log "[CephWin] WARNING: Multiple staged $DisplayName MSI files matched '$FallbackPattern'. Using '$($matches[0].Name)'." -Console
        }
        else {
            Write-Log "[CephWin] Using staged $DisplayName MSI by fallback pattern '$FallbackPattern': $($matches[0].Name)" -Console
        }

        return $matches[0].FullName
    }

    if (Test-Path -Path $storageAddonManifestPath) {
        try {
            $manifest = Get-FromYamlFile -Path $storageAddonManifestPath
            $cephImpl = @($manifest.spec.implementations | Where-Object { "$($_.name)" -eq 'ceph' } | Select-Object -First 1)
            if ($cephImpl.Count -gt 0) {
                $windowsCurlEntries = @($cephImpl[0].offline_usage.windows.curl)

                $cephEntry = @($windowsCurlEntries |
                        Where-Object {
                            $entryUrl = "$($_.url)".Trim()
                            $entryDestination = "$($_.destination)".Trim()
                            $urlLeaf = [System.IO.Path]::GetFileName($entryUrl)
                            $destinationLeaf = [System.IO.Path]::GetFileName($entryDestination)
                            ($urlLeaf -match '(?i)^ceph.*\.msi$') -or ($destinationLeaf -match '(?i)^ceph.*\.msi$')
                        } |
                        Select-Object -First 1)
                if ($cephEntry.Count -gt 0) {
                    $cephMsiUrl = "$($cephEntry[0].url)".Trim()
                    $cephMsiDestination = "$($cephEntry[0].destination)".Trim()
                }

                $dokanyEntry = @($windowsCurlEntries |
                        Where-Object {
                            $entryUrl = "$($_.url)".Trim()
                            $entryDestination = "$($_.destination)".Trim()
                            $urlLeaf = [System.IO.Path]::GetFileName($entryUrl)
                            $destinationLeaf = [System.IO.Path]::GetFileName($entryDestination)
                            ($urlLeaf -match '(?i)^dokan.*\.exe$') -or ($destinationLeaf -match '(?i)^dokan.*\.exe$')
                        } |
                        Select-Object -First 1)
                if ($dokanyEntry.Count -gt 0) {
                    $dokanyMsiUrl = "$($dokanyEntry[0].url)".Trim()
                    $dokanyMsiDestination = "$($dokanyEntry[0].destination)".Trim()
                }
            }
        }
        catch {
            Write-Log "[CephWin] WARNING: Could not resolve Windows MSI URLs from storage addon manifest: $($_.Exception.Message)" -Console
        }
    }
    else {
        Write-Log "[CephWin] WARNING: Storage addon manifest not found at '$storageAddonManifestPath'; MSI URLs cannot be resolved from manifest." -Console
    }

    if (-not [string]::IsNullOrWhiteSpace($dokanyMsiUrl)) {
        Write-Log "[CephWin] Using Dokany installer URL from storage addon manifest: $dokanyMsiUrl" -Console
    }
    if (-not [string]::IsNullOrWhiteSpace($cephMsiUrl)) {
        Write-Log "[CephWin] Using Ceph MSI URL from storage addon manifest: $cephMsiUrl" -Console
    }

    $cephMsiPath = Resolve-StagedMsiPath -DisplayName 'Ceph' -ManifestDestination $cephMsiDestination -FallbackPattern 'ceph*.msi'
    # Dokany is supported only via .exe installer in K2s.
    $dokanyMsiPath = Resolve-StagedMsiPath -DisplayName 'Dokany' -ManifestDestination $dokanyMsiDestination -FallbackPattern '*okan*.exe'

    return [pscustomobject]@{
        CephMsiPath   = "$cephMsiPath"
        CephMsiUrl    = $cephMsiUrl
        DokanyMsiPath = "$dokanyMsiPath"
        DokanyMsiUrl  = $dokanyMsiUrl
    }
}

<#
.SYNOPSIS
Installs the native Ceph client on a remote (VM-EXISTING) Windows worker node.

.DESCRIPTION
Opens a PowerShell remoting session to the Hyper-V worker VM (via Open-RemoteSession using the node's
VmName), copies Install-CephForWindows.ps1 and any locally staged MSIs onto the node, and runs the
installer remotely. Staged MSIs are copied so offline installs keep working; otherwise the remote
node downloads the MSIs itself using the provided proxy. Returns $true on success.
#>
function Install-CephOnRemoteWindowsNode {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$WindowsNode,
        [Parameter(Mandatory = $true)][pscustomobject]$Connection,
        [Parameter(Mandatory = $true)][pscustomobject]$MsiSettings,
        [string]$Proxy = ''
    )

    $nodeName = "$($WindowsNode.Name)".Trim()
    $vmName = "$($WindowsNode.VmName)".Trim()

    if ([string]::IsNullOrWhiteSpace($vmName)) {
        Write-Log "[CephWin] WARNING: Windows node '$nodeName' (NodeType '$($WindowsNode.NodeType)') has no VmName in cluster.json; cannot open a remote session. Run Install-CephForWindows.ps1 on it manually (mon host '$($Connection.MonitorEndpoints)', fsid '$($Connection.ClusterId)')." -Console
        return $false
    }

    $session = $null
    try {
        Write-Log "[CephWin] Opening remote session to Windows node '$nodeName' (VM '$vmName')." -Console
        $session = Open-RemoteSession -VmName $vmName -VmPwd (Get-DefaultTempPwd) -NoLog

        # Prepare a remote working directory and copy the installer plus any staged MSIs.
        $remoteDir = Invoke-Command -Session $session -ScriptBlock {
            $dir = Join-Path $env:TEMP ('k2s-ceph-win-' + [guid]::NewGuid().ToString())
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
            return $dir
        }

        Copy-Item -Path $installScript -Destination (Join-Path $remoteDir 'Install-CephForWindows.ps1') -ToSession $session -Force

        $remoteCephMsi = ''
        if (-not [string]::IsNullOrWhiteSpace($MsiSettings.CephMsiPath) -and (Test-Path -Path $MsiSettings.CephMsiPath)) {
            $remoteCephMsi = Join-Path $remoteDir (Split-Path -Leaf $MsiSettings.CephMsiPath)
            Copy-Item -Path $MsiSettings.CephMsiPath -Destination $remoteCephMsi -ToSession $session -Force
        }

        $remoteDokanyMsi = ''
        if (-not [string]::IsNullOrWhiteSpace($MsiSettings.DokanyMsiPath) -and (Test-Path -Path $MsiSettings.DokanyMsiPath)) {
            $remoteDokanyMsi = Join-Path $remoteDir (Split-Path -Leaf $MsiSettings.DokanyMsiPath)
            Copy-Item -Path $MsiSettings.DokanyMsiPath -Destination $remoteDokanyMsi -ToSession $session -Force
        }

        $remoteExit = Invoke-Command -Session $session -ArgumentList $remoteDir, $Connection, $MsiSettings, $remoteCephMsi, $remoteDokanyMsi, $Proxy -ScriptBlock {
            param($dir, $conn, $msi, $cephMsi, $dokanyMsi, $proxyUrl)

            $script = Join-Path $dir 'Install-CephForWindows.ps1'
            & $script -MonitorEndpoints $conn.MonitorEndpoints `
                -AdminKey $conn.AdminKey `
                -ClusterId $conn.ClusterId `
                -CephUser $conn.CephUser `
                -CephMsiPath $cephMsi `
                -CephMsiUrl $msi.CephMsiUrl `
                -DokanyMsiPath $dokanyMsi `
                -DokanyMsiUrl $msi.DokanyMsiUrl `
                -Proxy $proxyUrl

            $code = $LASTEXITCODE
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
            return $code
        }

        if ($remoteExit -ne 0) {
            Write-Log "[CephWin] ERROR: Native Ceph client installation on remote node '$nodeName' failed (exit code $remoteExit)." -Console -Error
            return $false
        }

        Write-Log "[CephWin] Native Ceph client installed on remote node '$nodeName'." -Console
        return $true
    }
    catch {
        Write-Log "[CephWin] ERROR: Remote installation on Windows node '$nodeName' failed: $($_.Exception.Message)" -Console -Error
        return $false
    }
    finally {
        if ($null -ne $session) {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
    }
}

<#
.SYNOPSIS
Mounts the CephFS filesystem on a remote (VM-EXISTING) Windows worker node.

.DESCRIPTION
Opens a PowerShell remoting session to the Hyper-V worker VM, copies Mount-CephForWindows.ps1 onto
the node and runs it there so CephFS is mounted (via ceph-dokan) and a startup task is registered.
Returns $true on success.
#>
function Mount-CephFsOnRemoteWindowsNode {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$WindowsNode,
        [Parameter(Mandatory = $true)][pscustomobject]$Connection,
        [Parameter(Mandatory = $true)][string]$MountPoint
    )

    $nodeName = "$($WindowsNode.Name)".Trim()
    $vmName = "$($WindowsNode.VmName)".Trim()

    if ([string]::IsNullOrWhiteSpace($vmName)) {
        Write-Log "[CephWin] WARNING: Windows node '$nodeName' has no VmName in cluster.json; cannot open a remote session to mount CephFS. Run Mount-CephForWindows.ps1 on it manually." -Console
        return $false
    }

    $session = $null
    try {
        Write-Log "[CephWin] Opening remote session to Windows node '$nodeName' (VM '$vmName') to mount CephFS." -Console
        $session = Open-RemoteSession -VmName $vmName -VmPwd (Get-DefaultTempPwd) -NoLog

        $remoteDir = Invoke-Command -Session $session -ScriptBlock {
            $dir = Join-Path $env:TEMP ('k2s-ceph-mount-' + [guid]::NewGuid().ToString())
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
            return $dir
        }

        Copy-Item -Path $mountScript -Destination (Join-Path $remoteDir 'Mount-CephForWindows.ps1') -ToSession $session -Force

        $remoteExit = Invoke-Command -Session $session -ArgumentList $remoteDir, $Connection, $MountPoint -ScriptBlock {
            param($dir, $conn, $mountPoint)

            $script = Join-Path $dir 'Mount-CephForWindows.ps1'
            & $script -CephFsName $conn.CephFsName -CephUser $conn.CephUser -MountPoint $mountPoint

            $code = $LASTEXITCODE
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
            return $code
        }

        if ($remoteExit -ne 0) {
            Write-Log "[CephWin] WARNING: CephFS mount on remote node '$nodeName' reported a problem (exit code $remoteExit)." -Console
            return $false
        }

        Write-Log "[CephWin] CephFS mounted on remote node '$nodeName'." -Console
        return $true
    }
    catch {
        Write-Log "[CephWin] WARNING: Remote CephFS mount on Windows node '$nodeName' failed: $($_.Exception.Message)" -Console
        return $false
    }
    finally {
        if ($null -ne $session) {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
    }
}

$windowsNodes = Get-WindowsClusterNodes
if ($windowsNodes.Count -eq 0) {
    Write-Log '[CephWin] No Windows worker nodes found in the cluster; skipping Windows Ceph native setup.' -Console
    exit 0
}

Write-Log "[CephWin] Found $($windowsNodes.Count) Windows worker node(s); configuring native Ceph client and host mount." -Console

$connection = Get-CephConnectionFromConfig -Config $Config
$windowsMountPoint = Get-WindowsCephMountPoint -Config $Config
$msiSettings = Resolve-WindowsMsiSettings -Config $Config

Write-Log "[CephWin] Using Windows CephFS mount path '$windowsMountPoint'." -Console

# Resolve the K2s transparent proxy for offline/online MSI download from the Windows host.
$proxy = ''
try {
    $kubeSwitchIp = Get-ConfiguredKubeSwitchIP
    if (-not [string]::IsNullOrWhiteSpace($kubeSwitchIp)) { $proxy = "http://${kubeSwitchIp}:8181" }
}
catch {
    Write-Log "[CephWin] WARNING: Could not determine the K2s proxy; MSI download (if needed) will run without one: $($_.Exception.Message)" -Console
}

$installFailures = @()
$mountFailures = @()

foreach ($windowsNode in $windowsNodes) {
    $nodeName = "$($windowsNode.Name)".Trim()
    $nodeType = "$($windowsNode.NodeType)".Trim()

    Write-Log "[CephWin] Installing native Ceph client on Windows node '$nodeName' (NodeType '$nodeType')." -Console

    $nodeInstalled = $false
    if ([string]::Equals($nodeType, 'HOST', [System.StringComparison]::OrdinalIgnoreCase)) {
        # The Windows worker node is the local host running the addon; install directly.
        & $installScript -MonitorEndpoints $connection.MonitorEndpoints `
            -AdminKey $connection.AdminKey `
            -ClusterId $connection.ClusterId `
            -CephUser $connection.CephUser `
            -CephMsiPath $msiSettings.CephMsiPath `
            -CephMsiUrl $msiSettings.CephMsiUrl `
            -DokanyMsiPath $msiSettings.DokanyMsiPath `
            -DokanyMsiUrl $msiSettings.DokanyMsiUrl `
            -Proxy $proxy `
            -ShowLogs:$ShowLogs

        if ($LASTEXITCODE -ne 0) {
            Write-Log "[CephWin] ERROR: Native Ceph client installation on '$nodeName' failed (exit code $LASTEXITCODE)." -Console -Error
            $installFailures += $nodeName
        }
        else {
            $nodeInstalled = $true
        }
    }
    else {
        # Added external Windows worker node (VM-EXISTING): install remotely over a PowerShell
        # remoting session to the Hyper-V worker VM.
        $remoteOk = Install-CephOnRemoteWindowsNode -WindowsNode $windowsNode -Connection $connection -MsiSettings $msiSettings -Proxy $proxy
        if ($remoteOk -ne $true) {
            $installFailures += $nodeName
        }
        else {
            $nodeInstalled = $true
        }
    }

    if (-not $nodeInstalled) {
        continue
    }

    # Client installed: mount CephFS (via ceph-dokan) and register the startup task so Windows pods
    # can consume the Ceph storage through a hostPath volume.
    Write-Log "[CephWin] Mounting CephFS on Windows node '$nodeName'." -Console
    if ([string]::Equals($nodeType, 'HOST', [System.StringComparison]::OrdinalIgnoreCase)) {
        & $mountScript -CephFsName $connection.CephFsName -CephUser $connection.CephUser -MountPoint $windowsMountPoint -ShowLogs:$ShowLogs
        if ($LASTEXITCODE -ne 0) {
            Write-Log "[CephWin] WARNING: CephFS mount on '$nodeName' reported a problem (exit code $LASTEXITCODE)." -Console
            $mountFailures += $nodeName
        }
    }
    else {
        $mountOk = Mount-CephFsOnRemoteWindowsNode -WindowsNode $windowsNode -Connection $connection -MountPoint $windowsMountPoint
        if ($mountOk -ne $true) {
            $mountFailures += $nodeName
        }
    }
}

if ($installFailures.Count -gt 0) {
    Write-Log "[CephWin] ERROR: Native Ceph client installation failed on node(s): $($installFailures -join ', ')." -Console -Error
    exit 1
}

if ($mountFailures.Count -gt 0) {
    Write-Log "[CephWin] WARNING: CephFS could not be confirmed mounted on node(s): $($mountFailures -join ', '). The native client is installed and the startup task is registered; verify with 'Get-ScheduledTask -TaskName K2s-CephFS-Mount' and check C:\ProgramData\ceph\out." -Console
}

# NOTE: Ceph on Windows does NOT use a containerized CSI node plugin. CephFS/RBD volumes are
# mounted natively through the host-installed Ceph client (WNBD + ceph-dokan) configured above.
# There is no upstream Windows cephcsi image, so no DaemonSet/manifests are applied here.

Write-Log '[CephWin] Windows Ceph native setup completed.' -Console
exit 0
