# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
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
    [switch] $ShowProgress = $false,
    [Parameter(Mandatory = $false, HelpMessage = 'Skip move of resources during upgrade')]
    [switch] $SkipResources = $false,
    [Parameter(Mandatory = $false, HelpMessage = 'Delete resource files after upgrade')]
    [switch] $DeleteFiles = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Config file for setting up new cluster')]
    [string] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Directory for resource backup')]
    [string] $BackupDir = ''
)
$infraModule = "$PSScriptRoot/../../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot/../../../../../addons\addons.module.psm1"


Import-Module $infraModule, $clusterModule, $addonsModule

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
function PrepareClusterUpgrade {
    param(
        [switch] $ShowProgress,
        [switch] $SkipResources,
        [switch] $ShowLogs,
        [string] $Proxy,
        [string] $BackupDir,
        [string] $AdditionalHooksDir,
        [ref] $coresVM,
        [ref] $memoryVM,
        [ref] $storageVM,
        [ref] $addonsBackupPath,
        [ref] $hooksBackupPath,
        [ref] $logFilePathBeforeUninstall
    )
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
        $coresVM.Value = Get-LinuxVMCores
        $memoryVM.Value = Get-LinuxVMMemory
        $storageVM.Value = Get-LinuxVMStorageSize
        Write-Log "Current settings for the Linux VM, Cores: $($coresVM.Value), Memory: $($memoryVM.Value) GB, Storage: $($storageVM.Value) GB" -Console

        # check for yaml tools
        Assert-YamlTools -Proxy $Proxy

        # export cluster resources
        if ($ShowProgress -eq $true) {
            Write-Progress -Activity 'Check if resources need to be exported..' -Id 1 -Status '3/10' -PercentComplete 30 -CurrentOperation 'Starting cluster, please wait..'
        }

        # kube tools folder changed from bin\exe to bin\kube
        $currentKubeToolsFolder = "$(Get-ClusterInstalledFolder)\bin\kube"
        if (!(Test-Path $currentKubeToolsFolder)) {
            $currentKubeToolsFolder = "$(Get-ClusterInstalledFolder)\bin\exe"
        }
        Export-ClusterResources -SkipResources:$SkipResources -PathResources $BackupDir -ExePath $currentKubeToolsFolder

        # Invoke backup hooks
        $hooksBackupPath.Value = Join-Path $BackupDir 'hooks'
        Invoke-UpgradeBackupRestoreHooks -HookType Backup -BackupDir $hooksBackupPath.Value -ShowLogs:$ShowLogs -AdditionalHooksDir $AdditionalHooksDir

        if ($ShowProgress -eq $true) {
            Write-Progress -Activity 'Backing up addons..' -Id 1 -Status '4/10' -PercentComplete 40 -CurrentOperation 'Backing up addons, please wait..'
        }

        # backup all addons
        $addonsBackupPath.Value = Join-Path $BackupDir 'addons'
        Backup-Addons -BackupDir $addonsBackupPath.Value

        # backup log file
        $logFilePathBeforeUninstall.Value = Join-Path $BackupDir 'k2s-before-uninstall.log'
        Backup-LogFile -LogFile $logFilePathBeforeUninstall.Value
        return $true
    }
    catch {
        Write-Log 'An ERROR occurred:' -Console
        Write-Log $_.ScriptStackTrace -Console
        Write-Log $_ -Console
        throw $_
    }
}

function PerformClusterUpgrade {
    param(
        [switch] $ShowProgress,
        [switch] $DeleteFiles,
        [switch] $ShowLogs,
        [switch] $ExecuteHooks,
        [string] $K2sPathToInstallFrom,
        [string] $Config,
        [string] $Proxy,
        [string] $BackupDir,
        [string] $AdditionalHooksDir,
        [string] $memoryVM,
        [string] $coresVM,
        [string] $storageVM,
        [string] $addonsBackupPath,
        [string] $hooksBackupPath,
        [string] $logFilePathBeforeUninstall
    )
    try {
        # uninstall of old cluster
        if ($ShowProgress -eq $true) {
            Write-Progress -Activity 'Uninstall cluster..' -Id 1 -Status '5/10' -PercentComplete 40 -CurrentOperation 'Uninstalling cluster, please wait..'
        }        
        Invoke-ClusterUninstall -ShowLogs:$ShowLogs -DeleteFiles:$DeleteFiles

        $logFilePath = Get-LogFilePath
        
        # ensure UTF-8 even for legacy encodings
        Get-Content $logFilePath -Encoding utf8 | Out-File $logFilePath -Encoding utf8

        # setup config might be still there if previous version stored the setup config in a different location
        Remove-SetupConfigIfExisting

        Start-Sleep -s 1

        # install of new cluster
        if ($ShowProgress -eq $true) {
            Write-Progress -Activity 'Install cluster..' -Id 1 -Status '6/10' -PercentComplete 50 -CurrentOperation 'Installing cluster, please wait..'
        }
          # Check if K2sPathToInstallFrom is null or empty and assign kubePath if so.
        if ([string]::IsNullOrEmpty($K2sPathToInstallFrom)) {
            $K2sPathToInstallFrom =  Get-KubePath
        }
        Invoke-ClusterInstall -K2sPathToInstallFrom $K2sPathToInstallFrom -ShowLogs:$ShowLogs -Config $Config -Proxy $Proxy -DeleteFiles:$DeleteFiles -MasterVMMemory $memoryVM -MasterVMProcessorCount $coresVM -MasterDiskSize $storageVM
        Wait-ForAPIServerInGivenKubePath -KubePath $K2sPathToInstallFrom

        # restore addons
        if ($ShowProgress -eq $true) {
            Write-Progress -Activity 'Apply not namespaced resources on cluster..' -Id 1 -Status '7/10' -PercentComplete 70 -CurrentOperation 'Apply not namespaced resources, please wait..'
        }
               
        if ($ExecuteHooks -eq $true) {
            
            Restore-Addons -BackupDir $addonsBackupPath
            # Invoke restore hooks
            Write-Log "Restore with executing hooks"            
            Invoke-UpgradeBackupRestoreHooks -HookType Restore -BackupDir $hooksBackupPath -ShowLogs:$ShowLogs -AdditionalHooksDir $AdditionalHooksDir
        } else {
            Write-Log "Restore without executing hooks"         
            Restore-Addons -BackupDir $addonsBackupPath -AvoidRestore
        }

        $kubeExeFolder = Get-KubeBinPathGivenKubePath -KubePath $K2sPathToInstallFrom     
        # import of resources
        Import-NotNamespacedResources -FolderIn $BackupDir -ExePath $kubeExeFolder
        if ($ShowProgress -eq $true) {
            Write-Progress -Activity 'Apply namespaced resources on cluster..' -Id 1 -Status '8/10' -PercentComplete 80 -CurrentOperation 'Apply namespaced resources, please wait..'
        }
        Import-NamespacedResources -FolderIn $BackupDir -ExePath $kubeExeFolder
        if ($ShowProgress -eq $true) {
            Write-Progress -Activity 'Restoring addons..' -Id 1 -Status '9/10' -PercentComplete 90 -CurrentOperation 'Restoring addons, please wait..'
        }

        # show completion
        if ($ShowProgress -eq $true) {
            Write-Progress -Activity 'Gathering executed upgrade information..' -Id 1 -Status '10/10' -PercentComplete 100 -CurrentOperation 'Upgrade successfully finished'
        }

        # restore log files
        Restore-LogFile -LogFile $logFilePathBeforeUninstall

        if ($ExecuteHooks -eq $true) { 
            # final message
            Write-Log "Upgraded successfully to K2s version: $(Get-ProductVersion) ($(Get-KubePath))" -Console
        }

        # info on env variables
        Write-RefreshEnvVariablesGivenKubePath -KubePath $K2sPathToInstallFrom
    }
    catch {
        Write-Log 'An ERROR occurred:' 
        Write-Log $_.ScriptStackTrace 
        Write-Log $_ 
        throw $_
    }
}
function Start-ClusterUpgrade {
    param(
        [Parameter(Mandatory = $false, HelpMessage = 'Show progress bar')]
        [switch] $ShowProgress = $false,
        [Parameter(Mandatory = $false, HelpMessage = 'Skip move of resources during upgrade')]
        [switch] $SkipResources = $false,
        [Parameter(Mandatory = $false, HelpMessage = 'Delete resource files after upgrade')]
        [switch] $DeleteFiles = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
        [switch] $ShowLogs = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Config file for setting up new cluster')]
        [string] $Config,
        [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
        [string] $Proxy,
        [Parameter(Mandatory = $false, HelpMessage = 'Skip takeover of container images')]
        [switch] $SkipImages = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Directory for resource backup')]
        [string] $BackupDir = ''
    )
    $errUpgrade = $null
        
    $coresVM = [ref]''
    $memoryVM = [ref]''
    $storageVM = [ref]''

    $addonsBackupPath = [ref]''
    $hooksBackupPath = [ref]''
    $logFilePathBeforeUninstall = [ref]''

    if ($BackupDir -eq '') {
        $BackupDir = Get-TempPath
    }

    Write-Log "The backup directory is '$BackupDir'"
   
    try {
        $prepareSuccess = PrepareClusterUpgrade -ShowProgress:$ShowProgress -SkipResources:$SkipResources -ShowLogs:$ShowLogs -Proxy $Proxy -BackupDir $BackupDir -AdditionalHooksDir $AdditionalHooksDir -coresVM $coresVM -memoryVM $memoryVM -storageVM $storageVM -addonsBackupPath $addonsBackupPath -hooksBackupPath $hooksBackupPath -logFilePathBeforeUninstall $logFilePathBeforeUninstall
        if (-not $prepareSuccess) {
            return $false
        }
    }
    catch {
        Write-Log 'An ERROR occurred:' -Console
        Write-Log $_.ScriptStackTrace -Console
        Write-Log $_ -Console
        $errUpgrade = $_
        Write-Error 'Unfortunately preliminary steps to export resources of current cluster failed, please check the logs for more information !'
        return $false
    }
    
    $installedFolder = Get-ClusterInstalledFolder
    try {
        PerformClusterUpgrade -ExecuteHooks:$true -ShowProgress:$ShowProgress -DeleteFiles:$DeleteFiles -ShowLogs:$ShowLogs -Config $Config -Proxy $Proxy -BackupDir $BackupDir -AdditionalHooksDir $AdditionalHooksDir -memoryVM $memoryVM.Value -coresVM $coresVM.Value -storageVM $storageVM.Value -addonsBackupPath $addonsBackupPath.Value -hooksBackupPath $hooksBackupPath.Value -logFilePathBeforeUninstall $logFilePathBeforeUninstall.Value
    }
    catch {       
        Write-Log 'System upgrade failed, will rollback to previous state !'
        try {
            #Execute the upgrade without executing the upgrade hooks and from the installed folder (folder used before upgrade)
            PerformClusterUpgrade -ExecuteHooks:$false -K2sPathToInstallFrom $installedFolder -ShowProgress:$ShowProgress -DeleteFiles:$DeleteFiles -ShowLogs:$ShowLogs -Config $Config -Proxy $Proxy -BackupDir $BackupDir -AdditionalHooksDir $AdditionalHooksDir -memoryVM $memoryVM.Value -coresVM $coresVM.Value -storageVM $storageVM.Value -addonsBackupPath $addonsBackupPath.Value -hooksBackupPath $hooksBackupPath.Value -logFilePathBeforeUninstall $logFilePathBeforeUninstall.Value
        }
        catch {
            Write-Log 'An ERROR occurred:' -Console
            Write-Log $_.ScriptStackTrace -Console
            Write-Log $_ -Console
            Write-Error 'System upgrade failed, please check the logs for more information !'
            return $false
        }
    }
    finally {
        if ($ShowProgress -eq $true) {
            Write-Progress -Activity 'Remove exported resources..' -Id 1 -Status '5/8' -PercentComplete 50 -CurrentOperation 'Remove exported resources, please wait..'
        }
        if (-not $errUpgrade) {
            # remove temp cluster resources
            Remove-ExportedClusterResources -PathResources $BackupDir -DeleteFiles:$true
        }
    }
    if ( $errUpgrade ) {
        return $false
    }
}

#####################################################
###############START OF UPGRADE######################
#####################################################

Write-Log 'Starting upgrading cluster' -Console
$ret = Start-ClusterUpgrade -ShowProgress:$ShowProgress -SkipResources:$SkipResources -DeleteFiles:$DeleteFiles -ShowLogs:$ShowLogs -Proxy $Proxy -BackupDir $BackupDir
if ( $ret ) {
    Restore-MergeLogFiles
}