# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Master VM memory')]
    [long] $MasterVMMemory = 6GB,
    [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for master VM (Linux)')]
    [long] $MasterVMProcessorCount = 6,
    [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of master VM (Linux)')]
    [uint64] $MasterDiskSize = 50GB,
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
    [switch] $DeleteFilesForOfflineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Force the installation online. This option is needed if the files for an offline installation are available but you want to recreate them.')]
    [switch] $ForceOnlineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Use WSL2 for hosting KubeMaster VM')]
    [switch] $WSL = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Append to log file (do not start from scratch)')]
    [switch] $AppendLogFile = $false
)

$installationParameters = @{
    MasterVMMemory = $MasterVMMemory
    MasterDiskSize = $MasterDiskSize
    MasterVMProcessorCount = $MasterVMProcessorCount
    Proxy = $Proxy
    ShowLogs = $ShowLogs
    DeleteFilesForOfflineInstallation = $DeleteFilesForOfflineInstallation
    ForceOnlineInstallation = $ForceOnlineInstallation
    WSL = $WSL
    AppendLogFile = $AppendLogFile
}

& "$PSScriptRoot\..\..\lib\scripts\buildonly\install\install.ps1" @installationParameters