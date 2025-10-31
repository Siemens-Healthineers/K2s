# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Dumps K2s system status to target folder.

.DESCRIPTION
Collects information about K2s from the respective nodes into log files and config files.
The log files and config files are later archived into a zip file.

.PARAMETER OpenDumpFolder
If set to $true, then the dump target folder will be opened in Windows explorer afterwards.
For non-interactive sessions, it is recommended to set it to $false.
Default: $true.

.PARAMETER ShowLogs
If set to $true, then the logs are written into the console with more verbosity.

.PARAMETER ZipFileName
Name of the final zip file.

.EXAMPLE
PS> .\dump.ps1
#>

Param (
    [Parameter(Mandatory = $false, HelpMessage = 'If set to $true, then the dump target folder will be opened in Windows explorer afterwards.')]
    [bool] $OpenDumpFolder = $true,

    [Parameter(Mandatory = $false, HelpMessage = 'If set to $true, then the logs are written into the console with more verbosity.')]
    [switch] $ShowLogs,

    [Parameter(Mandatory = $false, HelpMessage = 'Name of the final zip file.')]
    [string] $ZipFileName = ''
)

$ErrorActionPreference = 'Stop'
if ($Trace) {
    Set-PSDebug -Trace 1
}

$infraModule = "$PSScriptRoot/../../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"
Import-Module $infraModule, $nodeModule

Initialize-Logging -ShowLogs:$ShowLogs
Reset-LogFile -AppendLogFile

function Invoke-k2sLogCollection(
    [string] $LogDirectory,
    [string] $LogCollectionDirectory
) {
    if (-not (Test-Path $LogCollectionDirectory)) {
        New-Item -ItemType Directory -Path $LogCollectionDirectory -Force | Out-Null
    }
    Copy-Item -Path "$LogDirectory\*" -Destination $LogCollectionDirectory -Exclude '*.zip' -Force -Recurse
}

function Invoke-k2sConfigCollection(
    [string] $ConfigCollectionDirectory
) {
    if (-not (Test-Path $ConfigCollectionDirectory)) {
        New-Item -ItemType Directory -Path $ConfigCollectionDirectory -Force | Out-Null
    }

    $setupJsonFile = Get-SetupConfigFilePath
    $k2sConfigFile = Get-k2sConfigFilePath

    $Configs = @(
        $setupJsonFile, 
        $k2sConfigFile
    )

    foreach ($config in $Configs) {
        Copy-Item -Path $config -Destination $ConfigCollectionDirectory -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-LinuxNodeDetailsCollection(
    [string] $NodeDetailsDirectory
) {
    $isLinuxVMRunning = Get-IsControlPlaneRunning
    $linuxNodeName = Get-ConfigControlPlaneNodeHostname
    Write-Log "Node name: $linuxNodeName"
    if ($isLinuxVMRunning) {
        $linuxNodeDumpFile = Join-Path $NodeDetailsDirectory "$($linuxNodeName)-node.txt"
        (Invoke-CmdOnControlPlaneViaSSHKey 'uname -a').Output | Out-String | Write-OutputIntoDumpFile -DumpFilePath $linuxNodeDumpFile -Description 'KubeMaster~$ uname -a'
        (Invoke-CmdOnControlPlaneViaSSHKey 'cat /proc/version').Output | Out-String | Write-OutputIntoDumpFile -DumpFilePath $linuxNodeDumpFile -Description 'KubeMaster~$ cat /proc/version'
    }
}

function Invoke-HostDetailsCollection(
    [string] $NodeDetailsDirectory
) {
    $dumpFile = Join-Path $NodeDetailsDirectory "$(hostname)-node.txt"
    ([System.Environment]::OSVersion).ToString() | Out-String | Write-OutputIntoDumpFile -DumpFilePath $dumpFile -Description 'Host OS Version'
    (Get-Item 'HKLM:SOFTWARE\Microsoft\Windows NT\CurrentVersion').GetValue('DisplayVersion') | Out-String | Write-OutputIntoDumpFile -DumpFilePath $dumpFile -Description 'Host DisplayVersion'

    if (Test-Path 'C:\Windows\System32\systeminfo.exe' -ErrorAction SilentlyContinue) {
        systeminfo.exe | Out-String | Write-OutputIntoDumpFile -DumpFilePath $dumpFile -Description 'systeminfo.exe'
    }
    else {
        $hotFix = Get-HotFix
        if ($null -ne $hotFix) {
            $hotFix | Out-String | Write-OutputIntoDumpFile -DumpFilePath $dumpFile -Description 'Host HotFix details'
        }
        else {
            '<No hotfix>' | Write-OutputIntoDumpFile -DumpFilePath $dumpFile -Description 'Host HotFix details'
        }
    }

}

function Invoke-ClusterDiagnosticsCollection(
        [string] $ClusterDiagnosticsDir
) {
    Write-Log '[ClusterDiag] Starting cluster diagnostics collection...'

    if (-not (Test-Path $ClusterDiagnosticsDir)) {
        New-Item -ItemType Directory -Path $ClusterDiagnosticsDir -Force | Out-Null
    }

    Write-Log '[ClusterDiag] Collecting pods and namespaces...'
    $podsWide = (Invoke-CmdOnControlPlaneViaSSHKey "kubectl get pods -A -o wide").Output
    $podsFile = Join-Path $ClusterDiagnosticsDir "pods-wide.txt"
    $podsWide | Out-String | Write-OutputIntoDumpFile -DumpFilePath $podsFile -Description "kubectl get pods -A -o wide"

    Write-Log '[ClusterDiag] Parsing pod names and namespaces...'
    $podLines = $podsWide -split "`n" | Select-Object -Skip 1
    foreach ($line in $podLines) {
        $fields = $line -split '\s+'
        if ($fields.Length -ge 2) {
            $namespace = $fields[0]
            $podName = $fields[1]
            $podDir = Join-Path $ClusterDiagnosticsDir "$namespace-$podName"
            if (-not (Test-Path $podDir)) {
                New-Item -ItemType Directory -Path $podDir -Force | Out-Null
            }
            Write-Log "[ClusterDiag] Collecting diagnostics for pod $podName in namespace $namespace..."
            # Describe pod
            (Invoke-CmdOnControlPlaneViaSSHKey "kubectl describe pod $podName -n $namespace").Output | Out-String | Write-OutputIntoDumpFile -DumpFilePath (Join-Path $podDir "describe.txt") -Description "kubectl describe pod $podName -n $namespace"
            # Logs
            (Invoke-CmdOnControlPlaneViaSSHKey "kubectl logs $podName -n $namespace").Output | Out-String | Write-OutputIntoDumpFile -DumpFilePath (Join-Path $podDir "logs.txt") -Description "kubectl logs $podName -n $namespace"
            # Previous logs
            (Invoke-CmdOnControlPlaneViaSSHKey "kubectl logs --previous $podName -n $namespace").Output | Out-String | Write-OutputIntoDumpFile -DumpFilePath (Join-Path $podDir "logs-previous.txt") -Description "kubectl logs --previous $podName -n $namespace"
        }
    }

    Write-Log '[ClusterDiag] Collecting cluster events...'
    (Invoke-CmdOnControlPlaneViaSSHKey "kubectl get events -A").Output | Out-String | Write-OutputIntoDumpFile -DumpFilePath (Join-Path $ClusterDiagnosticsDir "events.txt") -Description "kubectl get events -A"

    Write-Log '[ClusterDiag] Collecting node descriptions...'
    (Invoke-CmdOnControlPlaneViaSSHKey "kubectl describe node kubemaster").Output | Out-String | Write-OutputIntoDumpFile -DumpFilePath (Join-Path $ClusterDiagnosticsDir "describe-kubemaster.txt") -Description "kubectl describe node kubemaster"

    $workerNode = (hostname).ToLower()
    (Invoke-CmdOnControlPlaneViaSSHKey "kubectl describe node $workerNode").Output | Out-String | Write-OutputIntoDumpFile -DumpFilePath (Join-Path $ClusterDiagnosticsDir "describe-worker.txt") -Description "kubectl describe node $workerNode"

    Write-Log '[ClusterDiag] Cluster diagnostics collection finished.'
}

function Invoke-HostDiagnosticsCollection(
        [string] $HostDiagnosticsDir
) {
    Write-Log '[HostDiag] Starting host diagnostics collection...'
    if (-not (Test-Path $HostDiagnosticsDir)) {
        New-Item -ItemType Directory -Path $HostDiagnosticsDir -Force | Out-Null
    }
    Write-Log '[HostDiag] Collecting ipconfig /allcompartments...'
    ipconfig /allcompartments | Out-String | Write-OutputIntoDumpFile -DumpFilePath (Join-Path $HostDiagnosticsDir "ipconfig-allcompartments.txt") -Description "ipconfig /allcompartments"
    Write-Log '[HostDiag] Collecting NetConnectionProfile...'
    Get-NetConnectionProfile | Sort-Object InterfaceAlias -Unique | Out-String | Write-OutputIntoDumpFile -DumpFilePath (Join-Path $HostDiagnosticsDir "netconnectionprofile.txt") -Description "Get-NetConnectionProfile"
    Write-Log '[HostDiag] Collecting MSINFO32...'
    $msinfoFile = Join-Path $HostDiagnosticsDir "$env:COMPUTERNAME`_MSINFO32.NFO"
    Start-Process -FilePath "MSINFO32.exe" -ArgumentList "/nfo $msinfoFile /categories +all" -Wait
    Write-Log '[HostDiag] Host diagnostics collection finished.'
}

Write-Log 'k2s system dump started' -Console

try {
    $dumpDirName = ''
    if ($ZipFileName -eq '') {
        $dumpDirName = "k2s-dump-$env:COMPUTERNAME-$(Get-Date -Format 'yyyyMMddTHHmmssfff')"
    }
    else {
        $dumpDirName = $ZipFileName
    }

    $logsDir = Get-k2sLogDirectory
    $dumpTargetDir = $logsDir

    $parentTempDir = [System.IO.Path]::GetTempPath()
    $tempDir = Join-Path $parentTempDir $dumpDirName
    $tempLogsDir = Join-Path $tempDir 'logs'
    $tempConfigDir = Join-Path $tempDir 'config\'
    $tempNetworkDir = Join-Path $tempDir 'networking\'
    $hostInfoDir = Join-Path $tempDir 'node\'
    $dumpTargetPath = Join-Path $dumpTargetDir "$dumpDirName.zip"

    # Host general information and node dump
    Write-Log 'Gathering node details..' -Console
    Invoke-HostDetailsCollection -NodeDetailsDirectory $hostInfoDir
    Invoke-LinuxNodeDetailsCollection -NodeDetailsDirectory $hostInfoDir

    # Cluster and host diagnostics collection
    $clusterDiagnosticsDir = Join-Path $tempDir 'cluster'
    $hostDiagnosticsDir = Join-Path $tempDir 'host'
    Write-Log 'Gathering cluster diagnostics..' -Console
    Invoke-ClusterDiagnosticsCollection -ClusterDiagnosticsDir $clusterDiagnosticsDir
    Write-Log 'Gathering host diagnostics..' -Console
    Invoke-HostDiagnosticsCollection -HostDiagnosticsDir $hostDiagnosticsDir

    # Log Collection
    Write-Log 'Gathering logs..' -Console
    Invoke-k2sLogCollection -LogDirectory:$logsDir -LogCollectionDirectory:$tempLogsDir

    # Config file collection
    Write-Log 'Gathering config files..' -Console
    Invoke-k2sConfigCollection -ConfigCollectionDirectory:$tempConfigDir

    # Network dump
    & $PSScriptRoot\network_dump.ps1 -DumpDir $tempNetworkDir
     
    # Final dump of logs and cleanup
    Write-Log "Dumping to $dumpTargetDir.." -Console
    Compress-Archive -Path $tempDir -DestinationPath $dumpTargetPath -CompressionLevel Optimal -Force
    Remove-Item -Path $tempDir -Recurse -Force

    Write-Log "Dump created at $dumpTargetPath" -Console
    Write-Log 'k2s system dump finished'

    if ($OpenDumpFolder -eq $true) {
        Write-Log 'Opening the dump folder..' -Console
        Invoke-Item $dumpTargetDir
    }
    else {
        Write-Log 'Skipping opening the dump folder' -Console
    }

    exit 0

}
catch {
    $exceptionString = $_ | Out-String
    Write-Log "Error occurred: $exceptionString" -Error
    exit -1
}


