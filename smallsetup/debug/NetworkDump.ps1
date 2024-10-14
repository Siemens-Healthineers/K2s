# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Gathers network information of the host.

.DESCRIPTION
Gathers networking details such HNS network stack and vfprules.

.EXAMPLE
# Outputs addons status information to default output stream as is
PS> .\NetworkDump.ps1 -DumpDir 'c:\var\log' -SwitchName 'L2Bridge'
#>

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Dumpfile directory. Default: <installation drive letter>:\var\log')]
    [string]$DumpDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Name of the switch to dump. Default: L2Bridge')]
    [string]$SwitchName = 'L2Bridge',
    [parameter(Mandatory = $false, HelpMessage = 'Status of Linux based Master')]
    [string]$LinuxMasterState = ''
)

#################################################################################################
# FUNCTIONS                                                                                     #
#################################################################################################

function ExecDumpCmd($CmdToExecute, $LineBreak, $DumpFilePath, [parameter(Mandatory = $false)] $CmdDisplay= '') {
    #Appends information to existing dump file, with assumption dump file is created
    Write-Output $LineBreak >> $DumpFilePath
    if ($CmdDisplay -eq '') {
        Write-Output "      $CmdToExecute        " >> $DumpFilePath
    } else {
        Write-Output "      $CmdDisplay        " >> $DumpFilePath
    }

    Write-Output $LineBreak >> $DumpFilePath
    Invoke-Expression $CmdToExecute >> $DumpFilePath
    Write-Output ' ' >> $DumpFilePath
}

#################################################################################################
# SCRIPT START                                                                                  #
#################################################################################################

# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1

$vfpModule = "$PSScriptRoot/VFP.psm1"

Import-Module $vfpModule -DisableNameChecking

$lineBreak = '**********************************************************************************************************************'

if ($DumpDir -eq '') {
    $DumpDir = "$($global:SystemDriveLetter):\var\log"
}

if (!(Test-Path $DumpDir)) {
    mkdir $DumpDir -Force | Out-Null
}

Write-Log 'Gathering network configuration..' -Console
$networkOutfile = Join-Path $DumpDir 'network.txt'
$vfpDumpFile = Join-Path $DumpDir 'vfprules.txt'

New-Item -ItemType Directory -Path $DumpDir -Force | Out-Null

# Network Interface information
ExecDumpCmd 'Get-NetIPInterface -IncludeAllCompartments | Sort-Object InterfaceMetric' $lineBreak $networkOutfile

#IP address and compartments
ExecDumpCmd 'ipconfig /all' $lineBreak $networkOutfile
ExecDumpCmd 'ipconfig /allcompartments' $lineBreak $networkOutfile

# Windows routes
ExecDumpCmd 'route print' $lineBreak $networkOutfile
ExecDumpCmd 'Get-NetRoute -IncludeAllCompartments | Sort-Object RouteMetric' $lineBreak $networkOutfile
ExecDumpCmd 'Get-NetNeighbor -IncludeAllCompartments | Sort-Object IPAddress' $lineBreak $networkOutfile
ExecDumpCmd 'arp -a' $lineBreak $networkOutfile

# VM Switch Dump
nmscrub -a -n -t -w > $DumpDir\nmscrub.txt
nvspinfo -a -i -h -D -p -d -m -q > $DumpDir\nvspinfo.txt

sc.exe queryex > $DumpDir\servicestatus.txt
sc.exe qc hns >> $DumpDir\servicestatus.txt
sc.exe qc vfpext >> $DumpDir\servicestatus.txt
sc.exe qc dnscache >> $DumpDir\servicestatus.txt
sc.exe qc iphlpsvc >> $DumpDir\servicestatus.txt
sc.exe qc BFE >> $DumpDir\servicestatus.txt
sc.exe qc Dhcp >> $DumpDir\servicestatus.txt
sc.exe qc hvsics >> $DumpDir\servicestatus.txt
sc.exe qc NetSetupSvc >> $DumpDir\servicestatus.txt
sc.exe qc mpssvc >> $DumpDir\servicestatus.txt
sc.exe qc nvagent >> $DumpDir\servicestatus.txt
sc.exe qc nsi >> $DumpDir\servicestatus.txt
sc.exe qc vmcompute >> $DumpDir\servicestatus.txt
sc.exe qc SharedAccess >> $DumpDir\servicestatus.txt
sc.exe qc CmService >> $DumpDir\servicestatus.txt
sc.exe qc vmms >> $DumpDir\servicestatus.txt

#Firewall rules
Get-NetFirewallRule -PolicyStore ActiveStore >> $DumpDir\firewallrules.txt

netsh int ipv4 sh excludedportrange TCP > $DumpDir\excludedportrange.txt
netsh int ipv4 sh excludedportrange UDP >> $DumpDir\excludedportrange.txt
netsh int ipv4 sh dynamicportrange TCP > $DumpDir\dynamicportrange.txt
netsh int ipv4 sh dynamicportrange UDP >> $DumpDir\dynamicportrange.txt
netsh int ipv4 sh tcpconnections > $DumpDir\tcpconnections.txt

# Dump the port info
$ports = Get-VfpPorts -SwitchName $switchName
$ports | Select-Object 'Port name', 'Mac Address', 'PortId', 'Switch Name' | Out-File $vfpDumpFile -Encoding ascii -Append

$hnsdiagExists = Get-Command hnsdiag.exe -ErrorAction SilentlyContinue
if ($hnsdiagExists) {
    hnsdiag list all -d > $DumpDir\hnsdiag.txt
    hcsdiag list > $DumpDir\hcsdiag.txt
}

$vfpCtrlExe = 'vfpctrl.exe'
$switchDumpSuccess = $false

foreach ($port in $ports) {
	$portGuid = $port.'Port name'
	Write-Output 'Policy for port Name: ' $portGuid | Out-File $vfpDumpFile -Encoding ascii -Append
	& $vfpCtrlExe /list-space /port $portGuid | Out-File $vfpDumpFile -Encoding ascii -Append
	& $vfpCtrlExe /list-mapping /port $portGuid | Out-File $vfpDumpFile -Encoding ascii -Append
	& $vfpCtrlExe /list-rule /port $portGuid | Out-File $vfpDumpFile -Encoding ascii -Append
    & $vfpCtrlExe /port $portGuid /get-rule-counter | Out-File $vfpDumpFile -Encoding ascii -Append
	& $vfpCtrlExe /port $portGuid /get-port-state | Out-File $vfpDumpFile -Encoding ascii -Append
	& $vfpCtrlExe /port $portGuid /list-nat-range | Out-File $vfpDumpFile -Encoding ascii -Append
    & $vfpCtrlExe /port $portGuid /get-flow-stats | Out-File $vfpDumpFile -Encoding ascii -Append
    & $vfpCtrlExe /port $portGuid /get-port-counter >> $DumpDir\ports.txt
    if (!$switchDumpSuccess) {
        & $vfpCtrlExe /switch $port.'Switch Name' /get-switch-forwarding-settings | Out-Null
        if ($?) {
            $switchDumpSuccess = $true
            & $vfpCtrlExe /switch $port.'Switch Name' /get-switch-forwarding-settings | Out-File $vfpDumpFile -Encoding ascii -Append
        }
    }
    Write-Output "`n###########################################################################`n" | Out-File $vfpDumpFile -Encoding ascii -Append
}

# Collect IP address & routes from Kubemaster
if ($LinuxMasterState -eq [Microsoft.HyperV.PowerShell.VMState]::Running) {
    ExecDumpCmd 'ExecCmdMaster "sudo ifconfig" -NoLog' $lineBreak $networkOutfile 'KubeMaster~$ sudo ifconfig'
    ExecDumpCmd 'ExecCmdMaster "ip route" -NoLog' $lineBreak $networkOutfile 'KubeMaster~$ ip route'
}
