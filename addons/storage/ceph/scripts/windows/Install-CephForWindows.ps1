# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs and configures the native Ceph client on a Windows node.

.DESCRIPTION
Installs the Ceph for Windows client (which bundles the WNBD RBD driver, rbd-wnbd.exe and
ceph-dokan.exe) together with the Dokany user-mode file system driver, then writes the Ceph client
configuration (ceph.conf) and the admin keyring so that CephFS/RBD volumes can be mounted natively on
the Windows node. This is the Windows counterpart of the CephFS CSI node plugin that the
ceph-csi-operator deploys on Linux nodes.

See https://docs.ceph.com/en/latest/install/windows-install/ for the underlying prerequisites
(WNBD driver, Dokany 2.0.5+, ceph.conf and keyring).

This script is intended to run ON the Windows node. It is dispatched by
scripts/windows/New-CephWindowsNode.ps1 (locally for a HOST Windows worker node, or remotely for a
VM-EXISTING Windows node).

.PARAMETER MonitorEndpoints
Comma separated list of Ceph monitor endpoints (host:port) of the provisioned cluster.

.PARAMETER AdminKey
The CephX key used to authenticate the Windows client (client.admin key by default).

.PARAMETER ClusterId
The Ceph cluster fsid.

.PARAMETER CephUser
The CephX user name (defaults to 'client.admin').

.PARAMETER CephMsiPath
Path to a locally staged Ceph for Windows MSI. Used for offline installations.

.PARAMETER CephMsiUrl
URL to download the Ceph for Windows MSI from when no local MSI is staged.

.PARAMETER DokanyMsiPath
Path to a locally staged Dokany MSI. Used for offline installations.

.PARAMETER DokanyMsiUrl
URL to download the Dokany MSI from when no local MSI is staged.

.PARAMETER Proxy
Optional HTTP proxy used for downloading the MSIs when they are not staged locally.
#>
Param(
    [parameter(Mandatory = $true, HelpMessage = 'Comma separated Ceph monitor endpoints (host:port)')]
    [string] $MonitorEndpoints,
    [parameter(Mandatory = $true, HelpMessage = 'CephX admin key')]
    [string] $AdminKey,
    [parameter(Mandatory = $true, HelpMessage = 'Ceph cluster fsid')]
    [string] $ClusterId,
    [parameter(Mandatory = $false, HelpMessage = 'CephX user name')]
    [string] $CephUser = 'client.admin',
    [parameter(Mandatory = $false, HelpMessage = 'Path to a locally staged Ceph for Windows MSI')]
    [string] $CephMsiPath = '',
    [parameter(Mandatory = $false, HelpMessage = 'URL of the Ceph for Windows MSI')]
    [string] $CephMsiUrl = '',
    [parameter(Mandatory = $false, HelpMessage = 'Path to a locally staged Dokany MSI')]
    [string] $DokanyMsiPath = '',
    [parameter(Mandatory = $false, HelpMessage = 'URL of the Dokany MSI')]
    [string] $DokanyMsiUrl = '',
    [parameter(Mandatory = $false, HelpMessage = 'Optional HTTP proxy for downloading MSIs')]
    [string] $Proxy = '',
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)

$infraModule = "$PSScriptRoot/../../../../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
if (Test-Path -Path $infraModule) {
    Import-Module $infraModule
    Initialize-Logging -ShowLogs:$ShowLogs
}
else {
    # When this script is executed on a remote Windows worker node it is copied outside of the K2s
    # module tree, so the infra module is not available. Provide minimal logging fallbacks so the
    # native client install remains fully self-contained.
    if (-not (Get-Command -Name 'Write-Log' -ErrorAction SilentlyContinue)) {
        function Write-Log { param([Parameter(ValueFromPipeline = $true)][string]$Message, [switch]$Console) process { Write-Output $Message } }
    }
    if (-not (Get-Command -Name 'Initialize-Logging' -ErrorAction SilentlyContinue)) {
        function Initialize-Logging { param([switch]$ShowLogs) }
    }
}

$cephProgramData = "$env:ProgramData\ceph"
$cephConfPath = "$cephProgramData\ceph.conf"
$cephKeyringPath = "$cephProgramData\keyring"

function Resolve-TransparentProxy {
    param(
        [string]$Proxy
    )

    if (-not [string]::IsNullOrWhiteSpace($Proxy)) {
        Write-Log "[CephWin] Using explicit proxy for MSI downloads: $Proxy" -Console
        return $Proxy
    }

    if (Get-Command -Name 'Get-ConfiguredKubeSwitchIP' -ErrorAction SilentlyContinue) {
        try {
            $kubeSwitchIp = Get-ConfiguredKubeSwitchIP
            if (-not [string]::IsNullOrWhiteSpace($kubeSwitchIp)) {
                $resolvedProxy = "http://${kubeSwitchIp}:8181"
                Write-Log "[CephWin] Using K2s transparent proxy for MSI downloads: $resolvedProxy" -Console
                return $resolvedProxy
            }
        }
        catch {
            Write-Log "[CephWin] WARNING: Could not resolve K2s transparent proxy automatically: $($_.Exception.Message)" -Console
        }
    }

    Write-Log '[CephWin] No proxy configured for MSI downloads; downloading directly.' -Console
    return ''
}

function Update-PathFromRegistry {
    # After an MSI install the machine PATH is written to the registry but the current PowerShell
    # process does not pick it up automatically. Merge it so Get-Command finds new binaries.
    $machinePath = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
    $userPath = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
    $env:PATH = (@($machinePath, $userPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ';'
}

function Test-CephWindowsClientInstalled {
    # ceph.exe (always in CephCLI feature) and ceph-dokan.exe are shipped by the Ceph for Windows
    # MSI. Presence of either on PATH or under the default install location indicates installed.
    Update-PathFromRegistry
    foreach ($binary in @('ceph.exe', 'ceph-dokan.exe')) {
        if ($null -ne (Get-Command $binary -ErrorAction SilentlyContinue)) { return $true }
    }
    foreach ($candidate in @(
        "$env:ProgramFiles\Ceph\bin\ceph.exe",
        "$env:ProgramFiles\Ceph\bin\ceph-dokan.exe",
        "$env:ProgramFiles\Ceph\ceph.exe"
    )) {
        if (Test-Path -Path $candidate) { return $true }
    }
    return $false
}

function Test-DokanyInstalled {
    $dokanDriver = Get-Service -Name 'dokan2' -ErrorAction SilentlyContinue
    if ($null -ne $dokanDriver) { return $true }
    if (Test-Path "$env:windir\System32\drivers\dokan2.sys") { return $true }
    return $false
}

function Resolve-MsiSource {
    param(
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [string]$LocalPath,
        [string]$Url,
        [string]$Proxy
    )

    if (-not [string]::IsNullOrWhiteSpace($LocalPath) -and (Test-Path -Path $LocalPath)) {
        Write-Log "[CephWin] Using locally staged $DisplayName MSI: $LocalPath" -Console
        return $LocalPath
    }

    if ([string]::IsNullOrWhiteSpace($Url)) {
        throw "No locally staged MSI and no download URL provided for $DisplayName. Stage the MSI for offline installation or configure a download URL."
    }

    $tempMsi = Join-Path ([System.IO.Path]::GetTempPath()) ("k2s-ceph-win-" + [guid]::NewGuid().ToString() + ".msi")
    Write-Log "[CephWin] Downloading $DisplayName MSI from $Url" -Console
    try {
        if (-not [string]::IsNullOrWhiteSpace($Proxy)) {
            Invoke-WebRequest -Uri $Url -OutFile $tempMsi -Proxy $Proxy -UseBasicParsing -ErrorAction Stop
        }
        else {
            Invoke-WebRequest -Uri $Url -OutFile $tempMsi -UseBasicParsing -ErrorAction Stop
        }
    }
    catch {
        throw "Failed to download $DisplayName MSI from '$Url': $($_.Exception.Message)"
    }
    return $tempMsi
}

function Install-MsiPackage {
    param(
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][string]$MsiPath,
        [string[]]$ExtraProperties = @()
    )

    Write-Log "[CephWin] Installing $DisplayName from $MsiPath" -Console
    $logFile = Join-Path ([System.IO.Path]::GetTempPath()) ("k2s-ceph-win-" + [guid]::NewGuid().ToString() + ".log")
    $msiArgs = @('/i', "`"$MsiPath`"", '/qn', '/norestart', '/l*v', "`"$logFile`"")
    if ($ExtraProperties.Count -gt 0) {
        $msiArgs += $ExtraProperties
    }
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow

    # 0 = success, 3010 = success but reboot required (WNBD driver install typically requests reboot).
    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        throw "$DisplayName installation failed (msiexec exit code $($process.ExitCode)). See log: $logFile"
    }

    if ($process.ExitCode -eq 3010) {
        Write-Log "[CephWin] $DisplayName installed successfully; a reboot is required to finish driver setup." -Console
    }
    else {
        Write-Log "[CephWin] $DisplayName installed successfully." -Console
    }
}

function Write-CephClientConfiguration {
    param(
        [Parameter(Mandatory = $true)][string]$MonitorEndpoints,
        [Parameter(Mandatory = $true)][string]$AdminKey,
        [Parameter(Mandatory = $true)][string]$ClusterId,
        [Parameter(Mandatory = $true)][string]$CephUser
    )

    if (-not (Test-Path -Path $cephProgramData)) {
        New-Item -Path $cephProgramData -ItemType Directory -Force | Out-Null
    }

    $monHostList = @()
    foreach ($monitor in ($MonitorEndpoints -split ',')) {
        $trimmed = $monitor.Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) { $monHostList += $trimmed }
    }
    if ($monHostList.Count -eq 0) {
        throw 'No valid monitor endpoints provided for the Windows ceph.conf'
    }
    $monHost = $monHostList -join ','

    Write-Log "[CephWin] Writing Ceph client configuration to $cephConfPath" -Console
    $cephConf = @"
[global]
    log to stderr = true
    run dir = C:/ProgramData/ceph/out
    crash dir = C:/ProgramData/ceph/out
    fsid = $ClusterId
    mon host = $monHost

[client]
    keyring = C:/ProgramData/ceph/keyring
    log file = C:/ProgramData/ceph/out/\$name.\$pid.log
    admin socket = C:/ProgramData/ceph/out/\$name.\$pid.asok
"@
    Set-Content -Path $cephConfPath -Value $cephConf -Encoding ascii -Force

    # Normalize the user name to the '<entity>' form used in a keyring section header.
    $entity = $CephUser
    if (-not $entity.StartsWith('client.')) { $entity = "client.$entity" }

    Write-Log "[CephWin] Writing Ceph client keyring to $cephKeyringPath" -Console
    $keyring = @"
[$entity]
    key = $AdminKey
"@
    Set-Content -Path $cephKeyringPath -Value $keyring -Encoding ascii -Force

    $outDir = "$cephProgramData\out"
    if (-not (Test-Path -Path $outDir)) {
        New-Item -Path $outDir -ItemType Directory -Force | Out-Null
    }
}

function Test-SecureBootDisabled {
    # The WNBD driver is not signed by Microsoft, so Secure Boot must be disabled for RBD mapping.
    try {
        $secureBoot = Confirm-SecureBootUEFI -ErrorAction Stop
        return (-not $secureBoot)
    }
    catch {
        # Confirm-SecureBootUEFI throws on legacy BIOS systems where Secure Boot does not apply.
        return $true
    }
}

function Resolve-CephCliPath {
    # ceph.exe is shipped by the Ceph for Windows MSI. Prefer PATH, then the default install location.
    # Refresh PATH first in case the MSI just ran in this session.
    Update-PathFromRegistry
    $cephCmd = Get-Command 'ceph.exe' -ErrorAction SilentlyContinue
    if ($null -ne $cephCmd) { return $cephCmd.Source }

    foreach ($candidate in @("$env:ProgramFiles\Ceph\bin\ceph.exe", "$env:ProgramFiles\Ceph\ceph.exe")) {
        if (Test-Path -Path $candidate) { return $candidate }
    }
    return ''
}

function Test-CephConnectivity {
    # Blog step 'Testing Connectivity': verify the Windows node can reach the Ceph monitors using the
    # freshly written ceph.conf and keyring. Non-fatal: the monitors may still be settling or the
    # ceph.exe CLI may be unavailable when only the CephFS (ceph-dokan) feature was installed.
    $cephCli = Resolve-CephCliPath
    if ([string]::IsNullOrWhiteSpace($cephCli)) {
        Write-Log '[CephWin] ceph.exe CLI not found; skipping connectivity verification (CephFS mounting via ceph-dokan is unaffected).' -Console
        return
    }

    Write-Log "[CephWin] Verifying connectivity to the Ceph cluster ($cephCli -c $cephConfPath status)" -Console
    try {
        $statusOutput = & $cephCli '-c' $cephConfPath '--connect-timeout' '15' 'status' 2>&1
        $statusOutput | Write-Log
        if ($LASTEXITCODE -eq 0) {
            Write-Log '[CephWin] Ceph connectivity verified: the Windows node can reach the cluster monitors.' -Console
        }
        else {
            Write-Log "[CephWin] WARNING: 'ceph status' returned exit code $LASTEXITCODE. The client is installed but could not reach the monitors yet. Check network/firewall to the mon endpoints and re-run 'ceph -c $cephConfPath status'." -Console
        }
    }
    catch {
        Write-Log "[CephWin] WARNING: Ceph connectivity check failed: $($_.Exception.Message). The client is installed; verify manually with 'ceph -c $cephConfPath status'." -Console
    }
}

try {
    Write-Log '[CephWin] Installing native Ceph client on Windows node' -Console

    # If no proxy is explicitly provided, try the K2s transparent proxy (kubeswitch:8181).
    $effectiveProxy = Resolve-TransparentProxy -Proxy $Proxy

    $secureBootEnabled = -not (Test-SecureBootDisabled)
    if ($secureBootEnabled) {
        Write-Log '[CephWin] WARNING: Secure Boot is ENABLED. The WNBD RBD driver cannot be installed (unsigned). Skipping WNBD driver feature; CephFS mounting via ceph-dokan will still work.' -Console
    }

    if (Test-DokanyInstalled) {
        Write-Log '[CephWin] Dokany is already installed; skipping Dokany installation.' -Console
    }
    else {
        $dokanySource = Resolve-MsiSource -DisplayName 'Dokany' -LocalPath $DokanyMsiPath -Url $DokanyMsiUrl -Proxy $effectiveProxy
        Install-MsiPackage -DisplayName 'Dokany' -MsiPath $dokanySource
    }

    if (Test-CephWindowsClientInstalled) {
        Write-Log '[CephWin] Ceph for Windows client is already installed; skipping client installation.' -Console
    }
    else {
        $cephSource = Resolve-MsiSource -DisplayName 'Ceph for Windows' -LocalPath $CephMsiPath -Url $CephMsiUrl -Proxy $effectiveProxy
        # When Secure Boot is enabled the WNBD kernel driver cannot be loaded (unsigned driver).
        # ADDLOCAL to install only the CephCLI feature, completely skipping WindowsCephDriver so its
        # InstallWindowsCephDriver custom action (wnbd-client.exe install-driver) never runs.
        # IMPORTANT: do NOT include VC142Redist in ADDLOCAL — it is a child of WindowsCephDriver in
        # the MSI feature tree, so adding it would silently pull WindowsCephDriver back in.
        # The Visual C++ 2019 runtime is expected to be pre-installed (via Dokany, Windows Update,
        # or the OS image). ceph-dokan.exe (CephFS via Dokany) is in CephCLI and works without WNBD.
        $cephMsiProps = if ($secureBootEnabled) { @('ADDLOCAL=CephCLI') } else { @() }
        Install-MsiPackage -DisplayName 'Ceph for Windows' -MsiPath $cephSource -ExtraProperties $cephMsiProps
        # Refresh PATH so the new Ceph binaries are visible to Get-Command in this session.
        Update-PathFromRegistry
    }

    Write-CephClientConfiguration -MonitorEndpoints $MonitorEndpoints -AdminKey $AdminKey -ClusterId $ClusterId -CephUser $CephUser

    # Blog step 'Testing Connectivity': confirm the node can reach the Ceph monitors.
    Test-CephConnectivity

    Write-Log '[CephWin] Native Ceph client installation and configuration completed.' -Console
    exit 0
}
catch {
    Write-Log "[CephWin] ERROR: $($_.Exception.Message)" -Console
    exit 1
}
