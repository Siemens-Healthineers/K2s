# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Starts the upgrade of the cluster.

.DESCRIPTION
Starts the upgrade of the cluster by exporting all resources and setting up a new cluster from current directory.


.EXAMPLE
# Starts the upgrade of the cluster
PS> .\Start-ClusterUpgrade.ps1

#>

Param(
    [Parameter(Mandatory = $false, HelpMessage = 'Show progress bar')]
    [switch]
    $ShowProgress = $false,
    [Parameter(Mandatory = $false, HelpMessage = 'Skip move of resources during upgrade')]
    [switch]
    $SkipResources = $false,
    [Parameter(Mandatory = $false, HelpMessage = 'Delete resource files after upgrade')]
    [switch] $DeleteFiles = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Config file for setting up new cluster')]
    [string] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy
)
$infraModule = "$PSScriptRoot/../../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot/../../../../../addons\addons.module.psm1"
$upgradeModule = "$PSScriptRoot\upgrade.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule, $upgradeModule

Initialize-Logging -ShowLogs:$ShowLogs

<#
 .Synopsis
  Upgrades the K8s cluster to new version from current directory.

  .Description
  Upgrades the K8s cluster to new version from current directory.

  .PARAMETER ShowProgress
  If set to $true, shows the overalls progress on operation-level.

 .Example
  Start-ClusterUpgrade

 .Example
  Start-ClusterUpgrade -ShowProgress $true -SkipResources $false

 .OUTPUTS
  Status object
#>
function Start-ClusterUpgrade {
    param(
        [Parameter(Mandatory = $false, HelpMessage = 'Show progress bar')]
        [switch]
        $ShowProgress = $false,
        [Parameter(Mandatory = $false, HelpMessage = 'Skip move of resources during upgrade')]
        [switch]
        $SkipResources = $false,
        [Parameter(Mandatory = $false, HelpMessage = 'Delete resource files after upgrade')]
        [switch] $DeleteFiles = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
        [switch] $ShowLogs = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Config file for setting up new cluster')]
        [string] $Config,
        [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
        [string] $Proxy,
        [Parameter(Mandatory = $false, HelpMessage = 'Skip takeover of container images')]
        [switch]
        $SkipImages = $false
    )
    $errUpgrade = $null
    $addonsBackupPath = $null
    $logFilePathBeforeUninstall = $null
    $tpath = $null
    $coresVM = $null
    $memoryVM = $null
    $storageVM = $null

    try {
        # start progress
        if ($ShowProgress -eq $true) {
            Write-Progress -Activity 'Gathering upgrade information...' -Id 1 -Status '0/10' -PercentComplete 0 -CurrentOperation 'Starting upgrade'
        }

        # check if cluster is installed
        $setupInfo = Get-SetupInfo
        if (!$($setupInfo.Name)) {
            $msg = 'No upgrade possible, since no previous version of K2s is installed.'
            Write-Progress -Activity $msg -Id 1 -Status '10/10' -PercentComplete 100 -CurrentOperation 'Upgrade successfully finished'
            Write-Log $msg -Console
            return $false
        }
        if ($setupInfo.Name -ne 'k2s') {
            throw "Upgrade is only available for 'k2s' setup"
        }

        # retrieve folder where current K2s package is located
        if ($ShowProgress -eq $true) {
            Write-Progress -Activity 'Checking if cluster is installed..' -Id 1 -Status '1/10' -PercentComplete 10 -CurrentOperation 'Cluster availability'
        }

        Assert-UpgradeOperation

        # check cluster is running
        if ($ShowProgress -eq $true) {
            Write-Progress -Activity 'Checking cluster state..' -Id 1 -Status '2/10' -PercentComplete 20 -CurrentOperation 'Starting cluster, please wait..'
        }

        Enable-ClusterIsRunning -ShowLogs:$ShowLogs

        # keep current settings from cluster
        $coresVM = Get-LinuxVMCores
        $memoryVM = Get-LinuxVMMemory
        $storageVM = Get-LinuxVMStorageSize
        Write-Log "Current settings for the Linux VM, Cores: $coresVM, Memory: $memoryVM GB, Storage: $storageVM GB" -Console

        # check for yaml tools
        Assert-YamlTools -Proxy $Proxy

        # export cluster resources
        if ($ShowProgress -eq $true) {
            Write-Progress -Activity 'Check if resources need to be exported..' -Id 1 -Status '3/10' -PercentComplete 30 -CurrentOperation 'Starting cluster, please wait..'
        }
        
        $tpath = Get-TempPath
        $currentExeFolder = "$(Get-ClusterInstalledFolder)\bin\exe"
        Export-ClusterResources -SkipResources:$SkipResources -PathResources $tpath -ExePath $currentExeFolder
        if ($ShowProgress -eq $true) {
            Write-Progress -Activity 'Backing up addons..' -Id 1 -Status '4/10' -PercentComplete 40 -CurrentOperation 'Backing up addons, please wait..'
        }

        # backup all addons
        $addonsBackupPath = Join-Path $tpath 'addons'
        Backup-Addons -BackupDir $addonsBackupPath

        # backup log file
        $logFilePathBeforeUninstall = Join-Path $tpath 'k2s-before-uninstall.log'
        Backup-LogFile -LogFile $logFilePathBeforeUninstall
    }
    catch {
        Write-Log 'An ERROR occurred:' -Console
        Write-Log $_.ScriptStackTrace -Console
        Write-Log $_ -Console
        $errUpgrade = $_
        Write-Log 'Unfortunately preliminary steps to export resources of current cluster failed, please check the logs for more information !' -Console
        return $false
    }
    try {
        # uninstall of old cluster
        if ($ShowProgress -eq $true) {
            Write-Progress -Activity 'Uninstall cluster..' -Id 1 -Status '5/10' -PercentComplete 40 -CurrentOperation 'Uninstalling cluster, please wait..'
        }
        Invoke-ClusterUninstall -ShowLogs:$ShowLogs -DeleteFiles:$DeleteFiles
        
        $logFilePath = Get-LogFilePath
        Get-Content $logFilePath -Encoding utf8 | Out-File $logFilePath -Encoding utf8

        Start-Sleep -s 1

        # install of new cluster
        if ($ShowProgress -eq $true) {
            Write-Progress -Activity 'Install cluster..' -Id 1 -Status '6/10' -PercentComplete 50 -CurrentOperation 'Installing cluster, please wait..'
        }
        Invoke-ClusterInstall -ShowLogs:$ShowLogs -Config $Config -Proxy $Proxy -DeleteFiles:$DeleteFiles -MasterVMMemory $memoryVM -MasterVMProcessorCount $coresVM -MasterDiskSize $storageVM
        Wait-ForAPIServer

        # restore addons
        if ($ShowProgress -eq $true) {
            Write-Progress -Activity 'Apply not namespaced resources on cluster..' -Id 1 -Status '7/10' -PercentComplete 70 -CurrentOperation 'Apply not namespaced resources, please wait..'
        }
        Restore-Addons -BackupDir $addonsBackupPath

        $exeFolder = Get-KubeToolsPath
        # import of resources
        Import-NotNamespacedResources -FolderIn $tpath -ExePath $exeFolder
        if ($ShowProgress -eq $true) {
            Write-Progress -Activity 'Apply namespaced resources on cluster..' -Id 1 -Status '8/10' -PercentComplete 80 -CurrentOperation 'Apply namespaced resources, please wait..'
        }
        Import-NamespacedResources -FolderIn $tpath -ExePath $exeFolder
        if ($ShowProgress -eq $true) {
            Write-Progress -Activity 'Restoring addons..' -Id 1 -Status '9/10' -PercentComplete 90 -CurrentOperation 'Restoring addons, please wait..'
        }

        # show completion
        if ($ShowProgress -eq $true) {
            Write-Progress -Activity 'Gathering executed upgrade information..' -Id 1 -Status '10/10' -PercentComplete 100 -CurrentOperation 'Upgrade successfully finished'
        }

        # restore log files
        Restore-LogFile -LogFile $logFilePathBeforeUninstall

        # final message
        Write-Log "Upgraded successfully to K2s version: $(Get-ProductVersion) ($(Get-KubePath))" -Console

        # info on env variables
        Write-RefreshEnvVariables
    }
    catch {
        Write-Log 'An ERROR occurred:' -Console
        Write-Log $_.ScriptStackTrace -Console
        Write-Log $_ -Console
        $errUpgrade = $_
    }
    finally {
        if ($ShowProgress -eq $true) {
            Write-Progress -Activity 'Remove exported resources..' -Id 1 -Status '5/8' -PercentComplete 50 -CurrentOperation 'Remove exported resources, please wait..'
        }
        # remove temp cluster resources
        Remove-ExportedClusterResources -PathResources $tpath
    }
    if ( $errUpgrade ) {
        return $false
    }
}

#####################################################
###############START OF UPGRADE######################
#####################################################

Write-Log 'Starting upgrading cluster' -Console
$ret = Start-ClusterUpgrade -ShowProgress:$ShowProgress -SkipResources:$SkipResources -DeleteFiles:$DeleteFiles -ShowLogs:$ShowLogs -Proxy $Proxy
if ( $ret ) {
    Restore-MergeLogFiles
}