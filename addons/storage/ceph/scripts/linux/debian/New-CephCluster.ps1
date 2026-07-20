# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Creates a new Ceph cluster on a Debian Linux target node.

.DESCRIPTION
Invoked by the storage/ceph addon Enable.ps1 when ceph-config.json sets
'clusterMode' to a value other than 'existing' and 'clusterDistribution' resolves
to 'debian12' or 'debian13'. Provisions a fresh Ceph cluster on the node identified by -NodeIp and
writes the resulting connection details (monitorEndpoints, cephKey, clusterId) back
into the provided configuration so the subsequent CSI installation can connect.

.PARAMETER NodeIp
IP address of the target node that will host the new Ceph cluster
(ceph-config.json 'clusterHostNodeIp').

.PARAMETER Config
The parsed ceph-config.json object.

.PARAMETER ShowLogs
If log output shall be streamed also to CLI output.
#>
Param(
    [parameter(Mandatory = $true, HelpMessage = 'IP address of the target Ceph host node')]
    [string] $NodeIp,
    [parameter(Mandatory = $false, HelpMessage = 'Parsed ceph-config.json object')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)

$infraModule = "$PSScriptRoot/../../../../../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../../../../../lib/modules/k2s/k2s.node.module/k2s.node.module.psm1"
$clusterConfigModule = "$PSScriptRoot/../../../../../../lib/modules/k2s/k2s.infra.module/config/cluster.config.module.psm1"
$proxyModule = "$PSScriptRoot/../../../../../../lib/modules/k2s/k2s.node.module/windowsnode/proxy/proxy.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterConfigModule, $proxyModule
Initialize-Logging -ShowLogs:$ShowLogs

Write-Log "[Ceph] Creating new Ceph cluster on node '$NodeIp'" -Console

function Get-CephBootstrapImageFromStorageManifest {
    $manifestPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\addon.manifest.yaml'
    $manifestPath = [System.IO.Path]::GetFullPath($manifestPath)

    if (!(Test-Path -Path $manifestPath)) {
        throw "[Ceph] Storage addon manifest not found at '$manifestPath'"
    }

    $manifestContent = Get-Content -Path $manifestPath -Raw
    if ([string]::IsNullOrWhiteSpace($manifestContent)) {
        throw "[Ceph] Storage addon manifest is empty: '$manifestPath'"
    }

    $imageRef = Get-Content -Path $manifestPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -like '- quay.io/ceph/ceph:*' } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($imageRef)) {
        throw "[Ceph] No quay.io/ceph/ceph:<tag> image found in storage addon additionalImages in '$manifestPath'"
    }

    return ($imageRef -replace '^-\s*', '')
}

<#
.SYNOPSIS
Runs the Debian Ceph cluster bootstrap script on the target node.

.DESCRIPTION
Copies create-ceph-cluster.sh to the target node and executes it remotely,
following the same pattern as Get-BuildahDebPackagesFromInternet. The remote
script bootstraps a new Ceph cluster and creates the CephFS filesystem/pool
named in the addon configuration.
#>
Function New-CephClusterOnNode {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = '',
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
        [string]$CephFsFilesystem = $(throw 'Argument missing: CephFsFilesystem'),
        [string]$CephFsPool = $(throw 'Argument missing: CephFsPool'),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$CephBootstrapImage = $(throw 'Argument missing: CephBootstrapImage'),
        [string]$Proxy = '',
        [string]$InstalledDistribution = 'debian'
    )

    Write-Log '[Ceph] Bootstrapping new Ceph cluster'

    $scriptSourcePath = "$PSScriptRoot\create-ceph-cluster.sh"

    $scriptOutput = Invoke-RemoteScript -LocalScriptPath $scriptSourcePath `
                        -UserName $UserName `
                        -IpAddress $IpAddress `
                        -UserPwd $UserPwd `
                        -Arguments @($Proxy, $CephBootstrapImage, $CephFsFilesystem) `
                        -CleanupAfterExecution `
                        -Retries 2

    Write-Log '[Ceph] Finished new Ceph cluster bootstrap'

    return $scriptOutput
}

<#
.SYNOPSIS
Extracts the Ceph dashboard connection details from cephadm bootstrap output.

.DESCRIPTION
cephadm prints a block like:
    Ceph Dashboard is now available at:
                 URL: https://<host>:8443/
                User: admin
            Password: <password>
plus a 'Cluster fsid: <fsid>' line. This parses those values and writes them
into the shared ceph-config object so Enable.ps1 can surface them to the user.
#>
Function Set-CephDashboardDetailsFromBootstrapOutput {
    param (
        [Parameter(Mandatory = $true)]
        $BootstrapOutput,
        [pscustomobject]$Config
    )

    if ($null -eq $Config) { return }

    $outputText = ($BootstrapOutput | Out-String)

    $getMatch = {
        param([string]$Pattern)
        $m = [regex]::Match($outputText, $Pattern)
        if ($m.Success) { return $m.Groups[1].Value.Trim() }
        return $null
    }

    $dashboardUrl = & $getMatch '(?m)^\s*URL:\s*(\S+)\s*$'
    $dashboardUser = & $getMatch '(?m)^\s*User:\s*(\S+)\s*$'
    $dashboardPassword = & $getMatch '(?m)^\s*Password:\s*(\S+)\s*$'
    $clusterFsid = & $getMatch '(?m)^\s*Cluster fsid:\s*(\S+)\s*$'

    if (-not [string]::IsNullOrWhiteSpace($dashboardUrl)) {
        $Config | Add-Member -NotePropertyName 'dashboardUrl' -NotePropertyValue $dashboardUrl -Force
    }
    if (-not [string]::IsNullOrWhiteSpace($dashboardUser)) {
        $Config | Add-Member -NotePropertyName 'dashboardUser' -NotePropertyValue $dashboardUser -Force
    }
    if (-not [string]::IsNullOrWhiteSpace($dashboardPassword)) {
        $Config | Add-Member -NotePropertyName 'dashboardPassword' -NotePropertyValue $dashboardPassword -Force
    }
    if (-not [string]::IsNullOrWhiteSpace($clusterFsid)) {
        $Config | Add-Member -NotePropertyName 'clusterId' -NotePropertyValue $clusterFsid -Force
    }

    # Log presence but do NOT log the password.
    Write-Log "[Ceph] Ceph dashboard available at '$dashboardUrl' (user '$dashboardUser')" -Console
}

<#
.SYNOPSIS
Adds/refreshes a Windows hosts-file entry mapping a hostname to an IP address.

.DESCRIPTION
cephadm builds the dashboard URL from the Ceph node's own hostname, which is not
resolvable from the K2s Windows host. This writes '<IpAddress> <HostName>' into
C:\Windows\System32\drivers\etc\hosts (removing any stale mapping for the same
hostname first) so the dashboard URL resolves. Idempotent.
#>
Function Add-CephWindowsHostEntry {
    param (
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][string]$IpAddress
    )

    $hostFile = 'C:\Windows\System32\drivers\etc\hosts'
    $entry = "$IpAddress $HostName"

    try {
        $content = @()
        if (Test-Path $hostFile) { $content = @(Get-Content -Path $hostFile) }

        # Drop any existing mapping for this hostname (e.g. a stale IP from a previous enable).
        $pattern = '^\s*\S+\s+' + [regex]::Escape($HostName) + '\s*$'
        $filtered = @($content | Where-Object { $_ -notmatch $pattern })

        if (($content -join "`n") -eq (($filtered + $entry) -join "`n")) {
            Write-Log "[Ceph] Hosts entry '$entry' already present" -Console
            return
        }

        $filtered += $entry
        Set-Content -Path $hostFile -Value $filtered -Encoding ascii -Force
        Write-Log "[Ceph] Added hosts entry '$entry' to '$hostFile'" -Console
    }
    catch {
        Write-Log "[Ceph] WARNING: Failed to update hosts file '$hostFile': $($_.Exception.Message)" -Console
    }
}

<#
.SYNOPSIS
Fetches the Ceph dashboard's TLS certificate and imports it into the Windows
trusted root store, returning its thumbprint.

.DESCRIPTION
The cephadm dashboard serves a self-signed certificate. To avoid the browser
'Not secure' warning, this performs a TLS handshake against <IpAddress>:<Port>,
captures the server certificate, and imports it into Cert:\LocalMachine\Root.
Returns the certificate thumbprint (so Disable.ps1 can remove it), or $null on
failure. Idempotent: skips import when the certificate is already trusted.
#>
Function Import-CephDashboardCertificate {
    param (
        [Parameter(Mandatory = $true)][string]$IpAddress,
        [Parameter(Mandatory = $true)][int]$Port
    )

    $remoteCert = $null
    $attempts = 5
    for ($i = 1; $i -le $attempts; $i++) {
        $tcpClient = $null
        $sslStream = $null
        try {
            $tcpClient = New-Object System.Net.Sockets.TcpClient
            $tcpClient.Connect($IpAddress, $Port)
            $sslStream = New-Object System.Net.Security.SslStream($tcpClient.GetStream(), $false, ([System.Net.Security.RemoteCertificateValidationCallback] { $true }))

            # Explicitly negotiate modern TLS. The default AuthenticateAsClient($host) overload
            # lets the OS pick the protocol, which on Windows PowerShell 5.1 can fail against the
            # cephadm dashboard (which serves TLS 1.2/1.3 only) with "A call to SSPI failed".
            # SslProtocols.Tls13 only exists on .NET Framework 4.8+, so add it defensively.
            $sslProtocols = [System.Security.Authentication.SslProtocols]::Tls12
            if ([enum]::GetNames([System.Security.Authentication.SslProtocols]) -contains 'Tls13') {
                $sslProtocols = $sslProtocols -bor [System.Security.Authentication.SslProtocols]::Tls13
            }
            $sslStream.AuthenticateAsClient($IpAddress, $null, $sslProtocols, $false)
            $remoteCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($sslStream.RemoteCertificate)
            break
        }
        catch {
            if ($i -eq $attempts) {
                Write-Log "[Ceph] WARNING: Could not retrieve Ceph dashboard certificate from ${IpAddress}:${Port}: $($_.Exception.Message)" -Console
            }
            else {
                Start-Sleep -Seconds 3
            }
        }
        finally {
            if ($sslStream) { $sslStream.Dispose() }
            if ($tcpClient) { $tcpClient.Dispose() }
        }
    }

    if ($null -eq $remoteCert) { return $null }

    $thumbprint = $remoteCert.Thumbprint
    try {
        $existing = Get-ChildItem -Path 'Cert:\LocalMachine\Root' -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $thumbprint }
        if ($existing) {
            Write-Log "[Ceph] Ceph dashboard certificate already trusted (thumbprint $thumbprint)" -Console
            return $thumbprint
        }

        $tempFile = New-TemporaryFile
        $certBytes = $remoteCert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
        [System.IO.File]::WriteAllBytes($tempFile.FullName, $certBytes)
        Import-Certificate -FilePath $tempFile.FullName -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null
        Remove-Item -Path $tempFile.FullName -Force -ErrorAction SilentlyContinue
        Write-Log "[Ceph] Imported Ceph dashboard certificate into trusted root (thumbprint $thumbprint)" -Console
        return $thumbprint
    }
    catch {
        Write-Log "[Ceph] WARNING: Failed to import Ceph dashboard certificate (thumbprint $thumbprint): $($_.Exception.Message)" -Console
        return $null
    }
}

<#
.SYNOPSIS
Makes the cephadm dashboard reachable and trusted from the K2s Windows host.

.DESCRIPTION
cephadm exposes the dashboard at https://<node-hostname>:8443/ with a self-signed
certificate. From the K2s host that hostname does not resolve and the certificate
is untrusted ('Not secure'). This adds a hosts entry (hostname -> node IP) so the
URL resolves and imports the dashboard certificate into the trusted root store so
the browser trusts it. The hostname and certificate thumbprint are written back
into the shared config so Enable.ps1 persists them and Disable.ps1 can undo them.
#>
Function Register-CephDashboardAccess {
    param (
        [Parameter(Mandatory = $true)][pscustomobject]$Config,
        [Parameter(Mandatory = $true)][string]$NodeIp
    )

    $dashboardUrl = "$($Config.dashboardUrl)".Trim()
    if ([string]::IsNullOrWhiteSpace($dashboardUrl)) {
        Write-Log "[Ceph] No dashboard URL resolved; skipping host entry and certificate trust setup." -Console
        return
    }

    $uri = $null
    try { $uri = [uri]$dashboardUrl } catch { $uri = $null }
    if ($null -eq $uri) {
        Write-Log "[Ceph] WARNING: Could not parse dashboard URL '$dashboardUrl'; skipping host entry and certificate trust setup." -Console
        return
    }

    $dashboardHost = $uri.Host
    $dashboardPort = if ($uri.IsDefaultPort) { 443 } else { $uri.Port }

    $parsedIp = $null
    $isIpHost = [System.Net.IPAddress]::TryParse($dashboardHost, [ref]$parsedIp)

    # 1) Make the node hostname resolve to the node IP (skip when cephadm already used an IP).
    if (-not $isIpHost) {
        Add-CephWindowsHostEntry -HostName $dashboardHost -IpAddress $NodeIp
        $Config | Add-Member -NotePropertyName 'dashboardHost' -NotePropertyValue $dashboardHost -Force
    }

    # 2) Trust the dashboard's self-signed certificate so the browser shows it as secure.
    #    Connect by IP (which is always reachable) to fetch the exact cert the server presents.
    $thumbprint = Import-CephDashboardCertificate -IpAddress $NodeIp -Port $dashboardPort
    if (-not [string]::IsNullOrWhiteSpace($thumbprint)) {
        $Config | Add-Member -NotePropertyName 'dashboardCertThumbprint' -NotePropertyValue $thumbprint -Force
    }
}

<#
.SYNOPSIS
Reads the actual Ceph connection details from the create-ceph-cluster.sh output.

.DESCRIPTION
create-ceph-cluster.sh emits K2S_CEPH_* marker lines with the values read back
from the freshly provisioned cluster (fsid, monitor endpoints, admin key, CephFS
filesystem/pool, user). This parses those markers and writes them into the shared
ceph-config object so Enable.ps1 persists them to ceph-config.json and the CSI
driver connects to the real cluster instead of the placeholder config values.
#>
Function Set-CephConnectionDetailsFromClusterOutput {
    param (
        [Parameter(Mandatory = $true)]
        $ClusterOutput,
        [pscustomobject]$Config
    )

    if ($null -eq $Config) { return }

    $lines = ($ClusterOutput | Out-String) -split "`r?`n"

    $getMarker = {
        param([string]$Name)
        $prefix = "$Name="
        $line = $lines | Where-Object { $_.Trim().StartsWith($prefix) } | Select-Object -Last 1
        if ($null -eq $line) { return $null }
        return $line.Trim().Substring($prefix.Length).Trim()
    }

    $fsid = & $getMarker 'K2S_CEPH_FSID'
    $monEndpoints = & $getMarker 'K2S_CEPH_MON_ENDPOINTS'
    $adminKey = & $getMarker 'K2S_CEPH_ADMIN_KEY'
    $fsName = & $getMarker 'K2S_CEPH_FS_NAME'
    $dataPool = & $getMarker 'K2S_CEPH_DATA_POOL'
    $cephUser = & $getMarker 'K2S_CEPH_USER'

    if (-not [string]::IsNullOrWhiteSpace($fsid)) {
        $Config | Add-Member -NotePropertyName 'clusterId' -NotePropertyValue $fsid -Force
    }
    if (-not [string]::IsNullOrWhiteSpace($monEndpoints)) {
        $Config | Add-Member -NotePropertyName 'monitorEndpoints' -NotePropertyValue $monEndpoints -Force
    }
    if (-not [string]::IsNullOrWhiteSpace($adminKey)) {
        $Config | Add-Member -NotePropertyName 'cephKey' -NotePropertyValue $adminKey -Force
    }
    if (-not [string]::IsNullOrWhiteSpace($fsName)) {
        $Config | Add-Member -NotePropertyName 'cephfsFilesystem' -NotePropertyValue $fsName -Force
    }
    if (-not [string]::IsNullOrWhiteSpace($dataPool)) {
        $Config | Add-Member -NotePropertyName 'cephfsPool' -NotePropertyValue $dataPool -Force
    }
    if (-not [string]::IsNullOrWhiteSpace($cephUser)) {
        $Config | Add-Member -NotePropertyName 'cephUser' -NotePropertyValue $cephUser -Force
    }

    # Do NOT print the resolved connection details to the CLI - they are already shown to the user
    # in the addon usage notes at the end of enable. Keep only a file-log line (no -Console) for
    # diagnostics, with the admin key masked.
    Write-Log "[Ceph] Resolved cluster connection details (fsid=$fsid, monitorEndpoints=$monEndpoints, cephfsFilesystem=$fsName, cephfsPool=$dataPool, cephUser=$cephUser, cephKey=<hidden>)"

    # The fsid, admin key and monitor endpoints are essential for the CSI driver to connect.
    # If any of them is missing the cluster provisioning did not complete correctly.
    $missing = @()
    if ([string]::IsNullOrWhiteSpace($fsid)) { $missing += 'clusterId (fsid)' }
    if ([string]::IsNullOrWhiteSpace($adminKey)) { $missing += 'cephKey (admin key)' }
    if ([string]::IsNullOrWhiteSpace($monEndpoints)) { $missing += 'monitorEndpoints' }

    if ($missing.Count -gt 0) {
        Write-Log "[Ceph] ERROR: Could not read essential Ceph connection details from the cluster: $($missing -join ', ')." -Console -Error
        return $false
    }

    return $true
}

$clusterHostNode = if ($Config) { "$($Config.clusterHostNode)".Trim() } else { '' }
$nodeConfig = $null
if (-not [string]::IsNullOrWhiteSpace($clusterHostNode)) {
    $nodeConfig = Get-NodeConfig -NodeName $clusterHostNode
}

if ($null -eq $nodeConfig) {
    Write-Log "[Ceph] WARNING: Node '$clusterHostNode' not found in cluster.json; falling back to NodeIp='$NodeIp' and userName='remote'" -Console
    $nodeUserName = 'remote'
} else {
    $nodeUserName = $nodeConfig.Username
    Write-Log "[Ceph] Resolved node connection from cluster.json: UserName='$nodeUserName', IpAddress='$($nodeConfig.IpAddress)'" -Console
}

$cephFsFilesystem = if ($Config) { "$($Config.cephfsFilesystem)".Trim() } else { '' }
$cephFsPool = if ($Config) { "$($Config.cephfsPool)".Trim() } else { '' }
if ([string]::IsNullOrWhiteSpace($Proxy)) {
    $kubeSwitchIp = Get-ConfiguredKubeSwitchIP
    if ([string]::IsNullOrWhiteSpace($kubeSwitchIp)) {
        throw '[NodePkg] Could not determine KubeSwitch IP for default proxy.'
    }
    $Proxy = "http://${kubeSwitchIp}:8181"
    Write-Log "[NodePkg] No proxy specified. Defaulting to K2s transparent proxy '$Proxy'." -Console
}
$cephBootstrapImage = Get-CephBootstrapImageFromStorageManifest

Write-Log "[Ceph] Using Ceph bootstrap image from addon manifest: $cephBootstrapImage" -Console

$bootstrapOutput = New-CephClusterOnNode -UserName $nodeUserName `
                      -UserPwd '' `
                      -IpAddress $NodeIp `
                      -CephFsFilesystem $cephFsFilesystem `
                      -CephFsPool $cephFsPool `
                      -CephBootstrapImage $cephBootstrapImage `
                      -Proxy $Proxy `
                      -InstalledDistribution 'debian'

# Surface the cephadm dashboard connection details (URL / user / password) back into the
# shared config object so Enable.ps1 can print them in the PowerShell console.
Set-CephDashboardDetailsFromBootstrapOutput -BootstrapOutput $bootstrapOutput -Config $Config

# Make the cephadm dashboard reachable and trusted from the K2s host: add a hosts entry so the
# node hostname resolves to the node IP, and import the dashboard's self-signed certificate into
# the Windows trusted root store (removing the browser 'Not secure' warning).
if ($null -ne $Config) {
    Register-CephDashboardAccess -Config $Config -NodeIp $NodeIp
}

# Read the ACTUAL Ceph connection values (monitor endpoints, admin key, filesystem/pool, fsid)
# from the freshly provisioned cluster back into the shared config object so Enable.ps1 persists
# them into ceph-config.json and connects the CSI driver to the real cluster.
$connectionResolved = Set-CephConnectionDetailsFromClusterOutput -ClusterOutput $bootstrapOutput -Config $Config

# Guard against any stray pipeline output from helper logging: use the last emitted value.
$connectionResolved = [bool]($connectionResolved | Select-Object -Last 1)

if (-not $connectionResolved) {
    Write-Log "[Ceph] ERROR: New Ceph cluster provisioning did not yield valid connection details on node '$NodeIp'." -Console -Error
    exit 1
}

Write-Log "[Ceph] Ceph cluster connection details resolved successfully"
exit 0
