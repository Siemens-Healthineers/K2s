# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

&$PSScriptRoot\..\common\GlobalVariables.ps1
. $PSScriptRoot\..\common\GlobalFunctions.ps1

$setupTypeModule = "$PSScriptRoot\..\status\SetupType.module.psm1"
$runningStateModule = "$PSScriptRoot\..\status\RunningState.module.psm1"
Import-Module $setupTypeModule, $runningStateModule

$processTools = @'

using System;
using System.Diagnostics;
using System.Text.RegularExpressions;

namespace Proc.Tools
{
  public static class exec
  {
    public static int runCommand(string executable, string args = "", string cwd = "", string verb = "runas") {

      //* Create your Process
      Process process = new Process();
      process.StartInfo.FileName = executable;
      process.StartInfo.UseShellExecute = false;
      process.StartInfo.CreateNoWindow = true;
      process.StartInfo.RedirectStandardOutput = true;
      process.StartInfo.RedirectStandardError = true;
      process.StartInfo.StandardOutputEncoding = System.Text.Encoding.GetEncoding("UTF-8");
      AppDomain.CurrentDomain.ProcessExit += (a, b) => process.Kill();
      Console.CancelKeyPress += (a, b) => process.Kill();

      //* Optional process configuration
      if (!String.IsNullOrEmpty(args)) { process.StartInfo.Arguments = args; }
      if (!String.IsNullOrEmpty(cwd)) { process.StartInfo.WorkingDirectory = cwd; }
      if (!String.IsNullOrEmpty(verb)) { process.StartInfo.Verb = verb; }

      //* Set your output and error (asynchronous) handlers
      process.OutputDataReceived += new DataReceivedEventHandler(OutputHandler);
      process.ErrorDataReceived += new DataReceivedEventHandler(OutputHandler);

      //* Start process and handlers
      process.Start();
      process.BeginOutputReadLine();
      process.BeginErrorReadLine();
      process.WaitForExit();

      //* Return the commands exit code
      return process.ExitCode;
    }
    static string CleanInput(string strIn)
    {
        // Replace invalid characters with empty strings.
        try
        {
            if (!string.IsNullOrEmpty(strIn))
                return Regex.Replace(strIn, @"[^\w\.@-d:]", " ",
                                 RegexOptions.None, TimeSpan.FromSeconds(1.5));
            else return string.Empty;
        }
        // If we timeout when replacing invalid characters,
        // we should return Empty.
        catch (RegexMatchTimeoutException)
        {
            return String.Empty;
        }
    }
    public static void OutputHandler(object sendingProcess, DataReceivedEventArgs outLine) {
      //Console.WriteLine(outLine.Data);
      Console.WriteLine(CleanInput(outLine.Data));
    }
  }
}
'@

Add-Type -TypeDefinition $processTools -Language CSharp

function Export-NotNamespacedResources {
    param (
        [parameter(Mandatory = $true, HelpMessage = 'Location where to install')]
        [string] $FolderOut,
        [Parameter(Mandatory = $true, HelpMessage = 'Directory where current cluster is installed')]
        [string] $ExePath
    )

    # get all the resources
    Write-Log "Export global (not namespaced) resources from existing cluster using $ExePath\kubectl.exe" -Console
    $resources = &$ExePath\kubectl.exe api-resources --verbs=list --namespaced=false

    # read cluster configuration json
    $global:JsonConfigFile = "$global:KubernetesPath\cfg\config.json"
    $clusterConfig = Get-Content $global:JsonConfigFile | Out-String | ConvertFrom-Json
    $excludedresources = 'componentstatuses', 'nodes', 'csinodes'
    $eresources = $clusterConfig.psobject.properties['smallsetup'].value.upgrade.excludedclusterresources
    if ( $eresources ) {
        $excludedresources = $eresources.Split(',')
    }

    # convert each line to array
    foreach ($item in $resources) {
        $entry = $item.split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
        if ( $entry[0] -ne 'NAME' ) {
            # check if resource makes sense
            if ($excludedresources -contains $entry[0]) { continue }
            # Write-Log  $entry
            # collect all resources
            $name = $entry[0]

            # check size of items
            $res1 = &$ExePath\kubectl.exe get $name -o json
            $nr = $res1 | & $global:BinDirectory\jq '.items | length'
            # if no items, export does not make sense
            Write-Log "Items in resource $name -> $nr"
            if ($nr -lt 1) { continue }

            # remove unwanted items
            $filter = 'del(.items[].status,
                .items[].metadata.creationTimestamp,
                .items[].metadata.resourceVersion,
                .items[].metadata.uid,
                .items[].metadata.selfLink,
                .items[].metadata.creationTimestamp,
                .items[].metadata.annotations,
                .items[].metadata.generation,
                .items[].metadata.ownerReferences,
                .items[].spec.finalizers,
                .items[].spec.claimRef,
                .metadata.creationTimestamp,
                .metadata.resourceVersion,
                .metadata.uid,
                .metadata.selfLink,
                .metadata.creationTimestamp,
                .metadata.annotations,
                .metadata.generation,
                .metadata.ownerReferences)'
            $filter = $filter -replace '\r*\n', ''
            $res2 = &$ExePath\kubectl.exe get $name -o json | & $global:BinDirectory\jq.exe $filter
            $res3 = $res2 | & $global:BinDirectory\yq eval - -P
            $file = "$FolderOut\\$name.yaml"
            Write-Log " $name -> $file"
            $res3 | Out-File -FilePath $file
        }
    }
}

function Export-NamespacedResources {
    param (
        [parameter(Mandatory = $true, HelpMessage = 'Location where to install')]
        [string] $FolderOut,
        [Parameter(Mandatory = $true, HelpMessage = 'Directory where current cluster is installed')]
        [string] $ExePath
    )

    # get all the resources
    Write-Log "Export namespaced resources from existing cluster using $ExePath\kubectl.exe" -Console
    $resources = &$ExePath\kubectl.exe api-resources --verbs=list --namespaced=true
    $namespaces = &$ExePath\kubectl.exe get ns --no-headers -o custom-columns=":metadata.name"

    # get excluded namespaces
    # read cluster configuration json
    $global:JsonConfigFile = "$global:KubernetesPath\cfg\config.json"
    $clusterConfig = Get-Content $global:JsonConfigFile | Out-String | ConvertFrom-Json
    # default namespaces are only the kubernetes ones, more shall be available in the default config file
    $excludednamespaces = 'kube-flannel', 'kube-node-lease', 'kube-public', 'kube-system'
    $enspaces = $clusterConfig.psobject.properties['smallsetup'].value.upgrade.excludednamespaces
    if ( $enspaces ) {
        $excludednamespaces = $enspaces.Split(',')
    }
    # excluded resource list
    $excludednamespacedresources = $clusterConfig.psobject.properties['smallsetup'].value.upgrade.excludednamespacedresources

    # iterate over all namespaces
    foreach ($namespace in $namespaces) {
        # check if namespace makes sense
        if ($excludednamespaces -contains $namespace) { continue }

        # create a folder
        $pathNamespace = New-Item "$FolderOut\\$namespace" -Type Directory
        Write-Log $pathNamespace

        # convert each line to array
        foreach ($item in $resources) {
            $entry = $item.split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
            if ( $entry[0] -ne 'NAME' ) {
                $name = $entry[0]
                # Write-Log $entry

                # check if resource needs to be excluded
                if ($excludednamespacedresources -contains $name) { continue }

                # check size of items
                $res1 = &$ExePath\kubectl.exe get $name -n $namespace -o json
                $nr = $res1 | & $global:BinDirectory\jq '.items | length'
                # if no items, export does not make sense
                Write-Log "Items in resource $name in namespace $namespace -> $nr"
                if ($nr -lt 1) { continue }

                # remove unwanted items
                $filter = 'del(.items[].status,
                .items[].metadata.creationTimestamp,
                .items[].metadata.resourceVersion,
                .items[].metadata.uid,
                .items[].metadata.selfLink,
                .items[].metadata.creationTimestamp,
                .items[].metadata.annotations,
                .items[].metadata.generation,
                .items[].metadata.ownerReferences,
                .items[].spec.finalizers,
                .metadata.creationTimestamp,
                .metadata.resourceVersion,
                .metadata.uid,
                .metadata.selfLink,
                .metadata.creationTimestamp,
                .metadata.annotations,
                .metadata.generation,
                .metadata.ownerReferences)'
                $filter = $filter -replace '\r*\n', ''
                # remove unwanted items
                $res2 = &$ExePath\kubectl.exe get $name -n $namespace -o json | & $global:BinDirectory\jq $filter

                $res3 = $res2 | & $global:BinDirectory\yq eval - -P
                $file = "$FolderOut\\$namespace\\$name.yaml"
                Write-Log " $name -> $file"
                $res3 | Out-File -FilePath $file
            }
        }
    }
}

function Import-NotNamespacedResources {
    param (
        [parameter(Mandatory = $true, HelpMessage = 'Location where to get the not namespaced resources')]
        [string] $FolderIn,
        [Parameter(Mandatory = $true, HelpMessage = 'Directory where current cluster is installed')]
        [string] $ExePath
    )

    # get all the resources
    Write-Log 'Import not namespaced resources from existing cluster' -Console
    $folderResources = Join-Path $FolderIn 'NotNamespaced'
    Get-ChildItem -Path $folderResources | Foreach-Object {
        $resource = $_.FullName
        Write-Log " Import resource with call 'kubectl apply -f $resource'"
        # don't show any ouput, import of resources can show some errors which have no relevance
        &$ExePath\kubectl.exe apply -f $resource >$null 2>&1
    }
}

function Import-NamespacedResources {
    param (
        [parameter(Mandatory = $true, HelpMessage = 'Location where to get the namespaced resources')]
        [string] $FolderIn,
        [Parameter(Mandatory = $true, HelpMessage = 'Directory where current cluster is installed')]
        [string] $ExePath
    )

    # get all the resources
    Write-Log 'Import namespaced resources from existing cluster' -Console
    $folderNamespaces = Join-Path $FolderIn 'Namespaced'
    Get-ChildItem -Path $folderNamespaces | Foreach-Object {
        $namespace = $_.Name
        Write-Log "Import namespace: $namespace" -Console
        &$ExePath\kubectl.exe create namespace $namespace >$null 2>&1
        $folderResources = Join-Path $folderNamespaces $namespace
        Get-ChildItem -Path $folderResources | Foreach-Object {
            $resource = $_.FullName
            Write-Log "Import resource with call 'kubectl apply -f $resource -n $namespace'"
            # don't show any ouput, import of resources can show some errors which have no relevance
            &$ExePath\kubectl.exe apply -f $resource -n $namespace >$null 2>&1
        }
    }
}

function Assert-ProductVersion {
    param (
        [parameter(Mandatory = $true, HelpMessage = 'Version installed')]
        [string] $VersionInstalled,
        [parameter(Mandatory = $true, HelpMessage = 'Version to be used')]
        [string] $VersionToBeUsed
    )

    # parse both versions
    Write-Log 'Check K2s version installed'
    $version1 = $VersionInstalled.Split('.')
    $version2 = $VersionToBeUsed.Split('.')
    if ($version1 -and $version2) {
        # check length
        if (($version1.Count -gt 1) -and ($version2.Count -gt 1)) {
            if ( ($version1[0] -eq $version2[0]) -and (([int]$version1[1]) -eq ([int]$version2[1] - 1)) ) {
                Write-Log 'Version combination of current/new package does allow the upgrade'
                return $true
            }
            else {
                Write-Log 'Version combination of current/new package version does not allow upgrade'
                return $false
            }
        }
        else {
            Write-Log 'Version information of current/new package is not valid'
            return $false
        }

    }
    else {
        Write-Log 'Version information of current/new package is not valid'
        return $false
    }
}

function Get-CurrentLineNumber {
    $MyInvocation.ScriptLineNumber
}

function Get-CurrentFileName {
    $MyInvocation.ScriptName
}

function Get-TempPath {
    # create temp path
    $temp = [System.IO.Path]::GetTempPath()
    [string] $name = [System.Guid]::NewGuid()
    $joined = (Join-Path $temp $name)
    $path = New-Item -ItemType Directory -Path $joined
    $path.FullName
}

function Export-ClusterResources {
    param (
        [Parameter(Mandatory = $true, HelpMessage = 'Skip move of resources during upgrade')]
        [switch]
        $SkipResources,
        [Parameter(Mandatory = $true, HelpMessage = 'Directory where to store resources')]
        [string]
        $PathResources,
        [Parameter(Mandatory = $true, HelpMessage = 'Directory where current cluster is installed')]
        [string]$ExePath
    )
    Write-Log 'Check if existing resources need to be exported'
    # takeover resources
    if ( -not $SkipResources ) {

        Write-Log "Existing resources will be exported to '$PathResources'"
        Write-Log "Directory '$PathResources'. Here all resources will be dumped"

        # export no namespaced resources
        $dir1 = Join-Path $PathResources 'NotNamespaced'
        $null = New-Item -ItemType Directory -Path $dir1
        Export-NotNamespacedResources -FolderOut $dir1 -ExePath $ExePath

        # export namespaced resources
        $dir2 = Join-Path $PathResources 'Namespaced'
        $null = New-Item -ItemType Directory -Path $dir2
        Export-NamespacedResources -FolderOut $dir2 -ExePath $ExePath
    }
}

function Remove-ExportedClusterResources {
    param (
        [Parameter(Mandatory = $false, HelpMessage = 'Path where resources are available')]
        [string]
        $PathResources,
        [Parameter(Mandatory = $false, HelpMessage = 'Delete resource files after upgrade')]
        [switch]
        $DeleteFiles = $false
    )
    # delete temp path
    if ( $DeleteFiles ) {
        if ( $PathResources -and (Test-Path $PathResources) ) {
            Remove-Item $PathResources -Recurse
        }
    }
}

function Enable-ClusterIsRunning {
    param (
        [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
        [switch] $ShowLogs = $false
    )

    Write-Log 'Check K2s cluster is running' -Console

    $setupType = Get-SetupInfo
    $clusterState = Get-RunningState -SetupType $setupType.Name

    if ($clusterState.IsRunning -ne $true) {
        $argsCall = 'start'
        if ( $ShowLogs ) { $argsCall += ' -o' }
        $rt = [Proc.Tools.exec]::runCommand('k2s', $argsCall)
        if ( $rt -eq 0 ) {
            Write-Log 'Start call of cluster successfully called'
        }
        else {
            Write-Log 'Error in calling start on K2s !'
        }
    }
}

function Get-ClusterInstalledFolder {
    $installFolder = Get-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_InstallFolder
    if ( [string]::IsNullOrEmpty($installFolder) ) {
        # we asume it is the old default
        $installFolder = 'C:\k'
    }
    return $installFolder
}

function Get-ClusterCurrentVersion {
    $currentVersion = Get-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_ProductVersion
    if ( [string]::IsNullOrEmpty($currentVersion) ) {
        # we asume it is the old default
        $currentVersion = '0.5'
    }
    return $currentVersion
}

function Assert-UpgradeOperation {
    $installFolder = Get-ClusterInstalledFolder
    $currentVersion = Get-ClusterCurrentVersion

    Write-Log "Preparing steps to upgrade from K2s version:$currentVersion ($installFolder) to K2s version:$global:ProductVersion ($global:KubernetesPath)" -Console

    # check of version (only lower minor version is supported)
    $validUpgrade = Assert-ProductVersion -VersionInstalled $currentVersion -VersionToBeUsed $global:ProductVersion
    if ( -not $validUpgrade) {
        throw "Upgrade not supported from $currentVersion to $global:ProductVersion !"
    }

    # check if install folder is the same as the current one
    if ( $global:KubernetesPath -eq $installFolder ) {
        throw 'Current cluster is available from same folder, upgrade makes no sense !'
    }

    # check current setup type
    $K8sSetup = Get-Installedk2sSetupType
    if ($K8sSetup -ne $global:SetupType_k2s) {
        throw 'Upgrade only supported in the default variant !'
    }
}

function Invoke-ClusterUninstall {
    param (
        [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
        [switch] $ShowLogs = $false,
        [Parameter(Mandatory = $false, HelpMessage = 'Delete package files after upgrade')]
        [switch] $DeleteFiles = $false
    )

    Write-Log 'Uninstall existing cluster' -Console
    $installFolder = Get-ClusterInstalledFolder
    $argsCall = 'uninstall'
    if ( $ShowLogs ) { $argsCall += ' -o' }
    if ( $DeleteFiles ) { $argsCall += ' -d' }
    Write-Log "Uninstall with arguments: $installFolder\k2s.exe $argsCall"
    $rt = [Proc.Tools.exec]::runCommand("$installFolder\k2s.exe", $argsCall)
    if ( $rt -eq 0 ) {
        Write-Log 'Uninstall of cluster successfully called'
    }
    else {
        Write-Log 'Error in calling uninstall on K2s !'
        throw 'Error: Not possible to uninstall old version !'
    }
}

function Invoke-ClusterInstall {
    param (
        [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
        [switch] $ShowLogs = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Config file for setting up new cluster')]
        [string] $Config,
        [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
        [string] $Proxy,
        [Parameter(Mandatory = $false, HelpMessage = 'Delete package files after upgrade')]
        [switch] $DeleteFiles = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of master VM (Linux)')]
        [string] $MasterVMMemory,
        [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for master VM (Linux)')]
        [string] $MasterVMProcessorCount,
        [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of master VM (Linux)')]
        [string] $MasterDiskSize
    )

    Write-Log 'Install cluster with the new version' -Console

    # copy executable since else we get ACCESS DENIED
    $texe = "$global:KubernetesPath\k2sx.exe"
    Copy-Item "$global:KubernetesPath\k2s.exe" -Destination $texe -Force -PassThru

    # start new executable and do an install
    $argsCall = 'install'
    if ( $ShowLogs ) { $argsCall += ' -o' }
    if ( -not [string]::IsNullOrEmpty($Config) ) { $argsCall += " -config $Config" }
    if ( -not [string]::IsNullOrEmpty($Proxy) ) { $argsCall += " --proxy $Proxy" }
    if ( $DeleteFiles ) { $argsCall += ' -d' }
    $argsCall += ' --append-log'
    if ( -not [string]::IsNullOrEmpty($MasterVMProcessorCount) ) { $argsCall += " --master-cpus $MasterVMProcessorCount" }
    if ( -not [string]::IsNullOrEmpty($MasterVMMemory) ) { $argsCall += " --master-memory $MasterVMMemory" }
    if ( -not [string]::IsNullOrEmpty($MasterDiskSize) ) { $argsCall += " --master-disk $MasterDiskSize" }
    Write-Log "Install with arguments: $global:KubernetesPath\k2s $argsCall"
    $rt = [Proc.Tools.exec]::runCommand("$global:KubernetesPath\k2sx.exe", $argsCall)
    if ( $rt -eq 0 ) {
        Write-Log 'Install of cluster successfully called'
    }
    else {
        Write-Log 'Error in calling install on K2s !'
        # remove temporary executable
        if (Test-Path $texe) {
            Remove-Item $texe -verbose
        }
        throw 'Error: Not possible to install new version !'
    }

    # remove temporary executable
    if (Test-Path $texe) {
        Remove-Item $texe -verbose
    }
}

function Assert-YamlTools {
    param (
        [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
        [string] $Proxy
    )

    Write-Log 'Check if existing yaml tools are available' -Console

    if ((Test-Path -Path "$global:BinPath\jq.exe") -ne $true) {
        &$global:KubernetesPath\smallsetup\windowsnode\downloader\DownloadYamlTools.ps1 -Proxy $Proxy -Deploy
        &$global:KubernetesPath\smallsetup\windowsnode\publisher\PublishYamlTools.ps1
    }
}

function Get-LinuxVMCores {
    $cores = Get-VMProcessor $global:VMName
    return $cores.Count.ToString()
}

function Get-LinuxVMMemory {
    $memory = Get-VMMemory $global:VMName
    return [math]::round($memory.Startup / 1GB, 2).ToString() + 'GB'
}

function Get-LinuxVMStorageSize {
    $disksize = Get-VM $global:VMName | ForEach { $Vm = $_; $_.HardDrives } | ForEach {
        $GetVhd = Get-VHD -Path $_.Path
        [pscustomobject]@{
            Vm            = $Vm.Name
            Name          = $_.Name
            Type          = $GetVhd.VhdType
            ProvisionedGB = ($GetVhd.Size / 1GB)
            CommittedGB   = ($GetVhd.FileSize / 1GB)
        }
    }
    return $disksize.ProvisionedGB.ToString() + 'GB'
}

function Backup-LogFile {
    param (
        [parameter(Mandatory = $false, HelpMessage = 'Name of the backup file')]
        [string] $LogFile
    )

    $installFolder = Get-ClusterInstalledFolder
    $driveLetter = $installFolder[0]

    Write-Log "Backup log file to $LogFile" -Console

    $oldLogFile = "$driveLetter$global:k2sLogFilePart"
    if (Test-Path -Path $oldLogFile) {
        Copy-Item $oldLogFile -Destination $LogFile
    }
}

function Restore-LogFile {
    param (
        [parameter(Mandatory = $false, HelpMessage = 'Name of the backup file')]
        [string] $LogFile
    )

    Write-Log "Restore log file $LogFile" -Console

    if (Test-Path -Path $LogFile) {
        $file = Split-Path $LogFile -Leaf
        $restore = "$($global:SystemDriveLetter):\var\log\$file"
        Copy-Item -Path $LogFile -Destination $restore
    }
}

function Restore-MergeLogFiles {
    Write-Log "Merge all logs to $global:k2sLogFile" -Console
    $merge = "$($global:SystemDriveLetter):\var\log\k2supgrade.log"
    $intermediate = "$($global:SystemDriveLetter):\var\log\k2s-*.log"
    Get-Content -Path $intermediate, $global:k2sLogFile -Encoding utf8 | Set-Content -Path $merge -Encoding utf8
    # Remove-Item -Path $intermediate, $global:k2sLogFile
    # Rename-Item -Path $merge -NewName $global:k2sLogFile
}

function Get-Container-Images {
    $installFolder = Get-ClusterInstalledFolder
    $ci = Invoke-Expression -Command "$installFolder\k2s.exe image ls"
    $containerimages = @()
    for ($i = 2; $i -lt $ci.length; $i++) {
        # $containerimages += ($ci[$i].Split(" ",[System.StringSplitOptions]::RemoveEmptyEntries))
        $containerimages += $ci[$i]
    }
    return $containerimages
}

Export-ModuleMember -Function Assert-UpgradeOperation, Enable-ClusterIsRunning, Assert-YamlTools, Export-ClusterResources,
Invoke-ClusterUninstall, Invoke-ClusterInstall, Import-NotNamespacedResources, Import-NamespacedResources, Remove-ExportedClusterResources,
Get-TempPath, Get-LinuxVMCores, Get-LinuxVMMemory, Get-LinuxVMStorageSize, Get-ClusterInstalledFolder, Backup-LogFile, Restore-LogFile, Restore-MergeLogFiles


