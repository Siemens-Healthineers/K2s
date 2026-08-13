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
Path to a locally staged Dokany installer EXE. Used for offline installations.

.PARAMETER DokanyMsiUrl
URL to download the Dokany installer EXE from when no local installer is staged.

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
    [parameter(Mandatory = $false, HelpMessage = 'Path to a locally staged Dokany installer EXE')]
    [string] $DokanyMsiPath = '',
    [parameter(Mandatory = $false, HelpMessage = 'URL of the Dokany installer EXE')]
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

# Marker recording which native client components K2s itself installed. Stored OUTSIDE the ceph
# program-data directory (which is removed on disable) so the uninstall can reliably tell whether
# Dokany / Ceph were installed by this addon or were pre-existing, shared components that other
# software may depend on. Never uninstall components K2s did not install.
$installMarkerDir = Join-Path $env:ProgramData 'k2s\storage-ceph'
$installMarkerPath = Join-Path $installMarkerDir 'windows-install-marker.json'

function Save-CephInstallMarker {
    param(
        [Nullable[bool]]$DokanyInstalledByK2s,
        [Nullable[bool]]$CephInstalledByK2s
    )

    $dokany = $false
    $ceph = $false
    try {
        if (Test-Path -Path $installMarkerPath) {
            $existing = Get-Content -Path $installMarkerPath -Raw | ConvertFrom-Json
            if ($existing.PSObject.Properties.Name -contains 'dokanyInstalledByK2s') { $dokany = [bool]$existing.dokanyInstalledByK2s }
            if ($existing.PSObject.Properties.Name -contains 'cephInstalledByK2s') { $ceph = [bool]$existing.cephInstalledByK2s }
        }
    }
    catch {
        Write-Log "[CephWin] WARNING: Could not read existing install marker '$installMarkerPath': $($_.Exception.Message)" -Console
    }

    # Once K2s has installed a component, keep it flagged as owned. A later re-enable that finds it
    # already present must not flip ownership back to false.
    if ($null -ne $DokanyInstalledByK2s) { $dokany = $dokany -or [bool]$DokanyInstalledByK2s }
    if ($null -ne $CephInstalledByK2s) { $ceph = $ceph -or [bool]$CephInstalledByK2s }

    try {
        if (-not (Test-Path -Path $installMarkerDir)) {
            New-Item -Path $installMarkerDir -ItemType Directory -Force | Out-Null
        }
        [pscustomobject]@{
            dokanyInstalledByK2s = $dokany
            cephInstalledByK2s   = $ceph
            updated              = (Get-Date).ToString('o')
        } | ConvertTo-Json | Set-Content -Path $installMarkerPath -Encoding ascii -Force
        Write-Log "[CephWin] Recorded native client install ownership (Dokany=$dokany, Ceph=$ceph) in '$installMarkerPath'." -Console
    }
    catch {
        Write-Log "[CephWin] WARNING: Could not write install marker '$installMarkerPath': $($_.Exception.Message)" -Console
    }
}

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
    # Avoid false positives from stale/partial service registrations.
    $driverPath = Join-Path $env:windir 'System32\drivers\dokan2.sys'
    $driverExists = Test-Path -Path $driverPath

    $service = Get-Service -Name 'dokan2' -ErrorAction SilentlyContinue
    $serviceExists = $null -ne $service

    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $hasUninstallEntry = $false
    try {
        $hasUninstallEntry = $null -ne (
            Get-ItemProperty -Path $uninstallPaths -ErrorAction SilentlyContinue |
                Where-Object { "$($_.DisplayName)" -match 'Dokan|Dokany' } |
                Select-Object -First 1
        )
    }
    catch {
        $hasUninstallEntry = $false
    }

    if ($driverExists) { return $true }
    if ($serviceExists -and $hasUninstallEntry) { return $true }
    return $false
}

function Test-PendingReboot {
    # The Dokany MSI (wrapped inside the DokanSetup.exe Wix Burn bundle) runs a 'CheckForRebootPending'
    # custom action that hard-fails with exit code 1603 whenever Windows has ANY pending reboot -
    # typically left behind by a previous Dokan driver uninstall (dokan2 service in StopPending) or by
    # unrelated updates queuing PendingFileRenameOperations. Detect this up front so we can surface a
    # clear, actionable message instead of a cryptic installer failure.
    $reasons = @()

    if (Get-Item 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' -ErrorAction SilentlyContinue) {
        $reasons += 'Component Based Servicing (RebootPending)'
    }
    if (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' -ErrorAction SilentlyContinue) {
        $reasons += 'Windows Update (RebootRequired)'
    }
    $pfro = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue).PendingFileRenameOperations
    if ($pfro) {
        $reasons += 'PendingFileRenameOperations'
    }

    return , $reasons
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

    $srcExt = [System.IO.Path]::GetExtension($Url).ToLower()
    if ($srcExt -notin @('.msi', '.exe')) { $srcExt = '.msi' }
    $tempMsi = Join-Path ([System.IO.Path]::GetTempPath()) ("k2s-ceph-win-" + [guid]::NewGuid().ToString() + $srcExt)
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

    $extension = [System.IO.Path]::GetExtension($MsiPath).ToLower()
    if ($extension -eq '.exe') {
        # DokanSetup.exe is a WiX Burn bundle wrapping Dokan_x64.msi (NOT plain NSIS). Use the documented
        # Burn switches: /quiet = silent, /norestart = do not reboot, /log = write a bundle log we can
        # parse for diagnostics. The bundle's inner MSI aborts with 1603 if a reboot is pending, so give
        # a clear message for that case rather than dumping the raw log.
        $burnLog = Join-Path ([System.IO.Path]::GetTempPath()) ("k2s-ceph-win-" + [guid]::NewGuid().ToString() + ".log")
        $exeArgs = @('/quiet', '/norestart', '/log', "`"$burnLog`"")
        $process = Start-Process -FilePath $MsiPath -ArgumentList $exeArgs -Wait -PassThru -NoNewWindow
        # 0 = success, 3010 = success but reboot required.
        if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
            $logText = ''
            if (Test-Path $burnLog) { $logText = (Get-Content $burnLog -Raw -ErrorAction SilentlyContinue) }
            if ($logText -match 'reboot is still pending' -or $process.ExitCode -eq 1603) {
                throw "$DisplayName installation failed (setup exit code $($process.ExitCode)) because a Windows reboot is pending (usually from a previous Dokan driver uninstall). Reboot this Windows node and re-run the addon enable. Bundle log: $burnLog"
            }
            throw "$DisplayName installation failed (setup exit code $($process.ExitCode)). Bundle log: $burnLog"
        }
    }
    else {
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

    if (Test-DokanyInstalled) {
        Write-Log '[CephWin] Dokany is already installed; skipping Dokany installation.' -Console
        $dokanyInstalledByK2s = $false
    }
    else {
        # The Dokany bundle refuses to install while a Windows reboot is pending and fails with a
        # cryptic 1603. Detect that here and stop with an actionable message before downloading.
        $rebootReasons = Test-PendingReboot
        if ($rebootReasons.Count -gt 0) {
            throw "Cannot install Dokany: a Windows reboot is pending ($($rebootReasons -join ', ')). The Dokany installer aborts with error 1603 while a reboot is pending (commonly left by a previous Dokan driver uninstall). Reboot this Windows node and re-run the addon enable."
        }
        $dokanySource = Resolve-MsiSource -DisplayName 'Dokany' -LocalPath $DokanyMsiPath -Url $DokanyMsiUrl -Proxy $effectiveProxy
        $dokanyExtension = [System.IO.Path]::GetExtension($dokanySource).ToLower()
        if ($dokanyExtension -ne '.exe') {
            throw "Dokany installer must be an .exe file. Resolved source '$dokanySource' is not supported."
        }
        Install-MsiPackage -DisplayName 'Dokany' -MsiPath $dokanySource
        $dokanyInstalledByK2s = $true
    }

    if (Test-CephWindowsClientInstalled) {
        Write-Log '[CephWin] Ceph for Windows client is already installed; skipping client installation.' -Console
        $cephInstalledByK2s = $false
    }
    else {
        $cephSource = Resolve-MsiSource -DisplayName 'Ceph for Windows' -LocalPath $CephMsiPath -Url $CephMsiUrl -Proxy $effectiveProxy
        # This addon uses CephFS (file) storage only, mounted natively via ceph-dokan (Dokany). The
        # WNBD RBD block-device driver is never needed, so ALWAYS install only the CephCLI feature and
        # skip WindowsCephDriver entirely. This avoids installing an unsigned kernel driver (which
        # also cannot load when Secure Boot is enabled) and the reboot its install requests.
        # IMPORTANT: do NOT include VC142Redist in ADDLOCAL — it is a child of WindowsCephDriver in
        # the MSI feature tree, so adding it would silently pull WindowsCephDriver back in.
        # The Visual C++ 2019 runtime is expected to be pre-installed (via Dokany, Windows Update,
        # or the OS image). ceph-dokan.exe (CephFS via Dokany) is in CephCLI and works without WNBD.
        $cephMsiProps = @('ADDLOCAL=CephCLI')
        Install-MsiPackage -DisplayName 'Ceph for Windows' -MsiPath $cephSource -ExtraProperties $cephMsiProps
        # Refresh PATH so the new Ceph binaries are visible to Get-Command in this session.
        Update-PathFromRegistry
        $cephInstalledByK2s = $true
    }

    # Persist which components this addon actually installed for diagnostics and reproducibility.
    Save-CephInstallMarker -DokanyInstalledByK2s $dokanyInstalledByK2s -CephInstalledByK2s $cephInstalledByK2s

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
