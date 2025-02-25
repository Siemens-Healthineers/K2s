# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

$infraModule = "$PSScriptRoot/../../k2s.infra.module/k2s.infra.module.psm1"

Import-Module $infraModule

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

$kubePath = Get-KubePath
$binPath = Get-KubeBinPath
$rootConfig = Get-RootConfigk2s
$productVersion = Get-ProductVersion
$controlPlaneName = Get-ConfigControlPlaneNodeHostname
$systemDriveLetter = Get-SystemDriveLetter
$logFilePath = Get-LogFilePath

$hooksDir = "$kubePath\LocalHooks"

function Invoke-Cmd {
    param (
        [parameter(Mandatory = $true, HelpMessage = 'Executable to run')]
        [string] $Executable,
        [parameter(Mandatory = $false, HelpMessage = 'Arguments to pass to executable')]
        [string] $Arguments,
        [parameter(Mandatory = $false, HelpMessage = 'Working directory for executable')]
        [string] $WorkingDirectory,
        [parameter(Mandatory = $false, HelpMessage = 'Verb to use for executable')]
        [string] $Verb = 'runas'
    )

    Write-Log "Run command: $Executable $Arguments" -Console
    $rt = [Proc.Tools.exec]::runCommand($Executable, $Arguments, $WorkingDirectory, $Verb)
    if ( $rt -eq 0 ) {
        Write-Log 'Command successfully called'
        return $rt
    }
    else {
        Write-Log 'Error in calling command!'
        throw 'Error: Not possible to call command!'
    }
}

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
    $excludedresources = 'componentstatuses', 'nodes', 'csinodes'
    $eresources = $rootConfig.upgrade.excludedclusterresources
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
            $nr = $res1 | & $binPath\jq '.items | length'
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
                .items[].metadata.generation,
                .items[].metadata.ownerReferences,
                .items[].spec.finalizers,
                .items[].spec.claimRef,
                .metadata.creationTimestamp,
                .metadata.resourceVersion,
                .metadata.uid,
                .metadata.selfLink,
                .metadata.creationTimestamp,
                .metadata.generation,
                .metadata.ownerReferences)'
            $filter = $filter -replace '\r*\n', ''
            $res2 = &$ExePath\kubectl.exe get $name -o json | & $binPath\jq.exe $filter
            $res3 = $res2 | & $binPath\yq eval - -P
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
    # default namespaces are only the kubernetes ones, more shall be available in the default config file
    $excludednamespaces = 'kube-flannel', 'kube-node-lease', 'kube-public', 'kube-system'
    $enspaces = $rootConfig.upgrade.excludednamespaces
    if ( $enspaces ) {
        $excludednamespaces = $enspaces.Split(',')
    }
    # excluded resource list
    $excludednamespacedresources = $rootConfig.upgrade.excludednamespacedresources

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
                $nr = $res1 | & $binPath\jq '.items | length'
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
                .items[].metadata.generation,
                .items[].metadata.ownerReferences,
                .items[].spec.finalizers,
                .metadata.creationTimestamp,
                .metadata.resourceVersion,
                .metadata.uid,
                .metadata.selfLink,
                .metadata.creationTimestamp,
                .metadata.generation,
                .metadata.ownerReferences)'
                $filter = $filter -replace '\r*\n', ''
                # remove unwanted items
                $res2 = &$ExePath\kubectl.exe get $name -n $namespace -o json | & $binPath\jq $filter

                $res3 = $res2 | & $binPath\yq eval - -P
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

function Assert-UpgradeVersionIsValid {
    param (
        [parameter(Mandatory = $true, HelpMessage = 'Version installed')]
        [string] $VersionInstalled,
        [parameter(Mandatory = $true, HelpMessage = 'Version to be used')]
        [string] $VersionToBeUsed
    )
    Write-Log 'Asserting upgrade version is valid..'

    $versionRegex = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$'

    if (-not ($VersionInstalled -match $versionRegex)) {
        Write-Log "The format of the currently installed version is invalid: current='$VersionInstalled', valid='1.22.333'"
        return $false
    }
    if (-not ($VersionToBeUsed -match $versionRegex)) {
        Write-Log "The format of the upgrade version is invalid: upgrade-version='$VersionToBeUsed', valid='1.22.333'"
        return $false
    }

    $currentVersion = [System.Version]::Parse($VersionInstalled)
    $nextVersion = [System.Version]::Parse($VersionToBeUsed)

    if ($nextVersion -le $currentVersion) {
        Write-Log "The upgrade version must be greater than the current version: current='$VersionInstalled', upgrade-version='$VersionToBeUsed'"
        return $false
    }

    return $nextVersion.Major - $currentVersion.Major -eq 0 -and $nextVersion.Minor - $currentVersion.Minor -le 1
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
    # delete resources
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

    $setupInfo = Get-SetupInfo
    $clusterState = Get-RunningState -SetupName $setupInfo.Name

    if ($clusterState.IsRunning -ne $true) {
        $argsCall = 'start'
        if ( $ShowLogs ) { $argsCall += ' -o' }
        $rt = [Proc.Tools.exec]::runCommand('k2s', $argsCall)
        if ( $rt -eq 0 ) {
            Write-Log 'Start call of cluster successfully called'
        }
        else {
            Write-Log 'Error in calling start on K2s!'
            throw 'Error: Not possible to start existing cluster!'
        }
    }
}

function Get-ClusterInstalledFolder {
    $installFolder = Get-ConfigInstallFolder
    if ( [string]::IsNullOrEmpty($installFolder) ) {
        # we asume it is the old default
        $installFolder = 'C:\k'
    }
    return $installFolder
}

function Get-ClusterCurrentVersion {
    $currentVersion = Get-ConfigProductVersion
    if ( [string]::IsNullOrEmpty($currentVersion) ) {
        # we asume it is the old default
        $currentVersion = '0.5'
    }
    return $currentVersion
}

function Assert-UpgradeOperation {
    $installFolder = Get-ClusterInstalledFolder
    $currentVersion = Get-ClusterCurrentVersion
    $nextVersion = $productVersion

    Write-Log "Preparing steps to upgrade from K2s version: $currentVersion ($installFolder) to K2s version: $nextVersion ($kubePath)" -Console

    # check of version (only lower minor version is supported and only between consecutive versions)
    $validUpgrade = Assert-UpgradeVersionIsValid -VersionInstalled $currentVersion -VersionToBeUsed $nextVersion
    if ( -not $validUpgrade) {
        throw "Upgrade not supported from $currentVersion to $nextVersion. Major version must be the same and minor version increase must be consecutive!"
    }

    # check if install folder is the same as the current one
    if ( $kubePath -eq $installFolder ) {
        throw 'Current cluster is available from same folder, upgrade makes no sense!'
    }

    # check current setup type
    $K8sSetup = Get-ConfigSetupType
    if ($K8sSetup -ne 'k2s') {
        throw 'Upgrade only supported in the default variant!'
    }
       
    # Minor version is the same or increased by one
    if(!(Restart-ClusterIfBuildVersionMismatch -CurrentVersion $currentVersion -NextVersion $nextVersion -InstallFolder $installFolder -KubePath $kubePath))
    {
        return $false
    }
    #  Upgrade to the next minor version
    Write-Log "Upgrade to the next minor version: $nextVersion"
    return $true
}

function Restart-ClusterIfBuildVersionMismatch {
    param (
        [string] $currentVersion,
        [string] $nextVersion,
        [string] $installFolder,
        [string] $kubePath
    )

    # Parse the version strings into major, minor, and patch components
    $currentVersionParsed = [System.Version]::Parse($currentVersion)
    $nextVersionParsed = [System.Version]::Parse($nextVersion)
    
    # Minor version is the same or increased by one
    if ($currentVersionParsed.Minor -eq $nextVersionParsed.Minor) {
        # If the patch version are different stop restart the cluster
        if ($currentVersionParsed.Build -ne $nextVersionParsed.Build) {
            Write-Log "Only build version mismatch: Current version is $currentVersion and next version is $nextVersion. Therefore only cluster restart is necessary." -Console
            RestartCluster -CurrentKubePath $installFolder -NextVersionKubePath $kubePath
            return $false
        }
        return $false
    }
    return $true
}

function RestartCluster {
    param (
        [string] $CurrentKubePath,
        [string] $NextVersionKubePath
    )
    $setupInfo = Get-SetupInfo
    $clusterState = Get-RunningState -SetupName $setupInfo.Name

    if ($clusterState.IsRunning -ne $true) {
        Write-Log 'Cluster is not running, no need to restart' -Console
        return
    }

    Write-Log 'Restarting the cluster..' -Console
    $currentExe = "$CurrentKubePath\k2s.exe"
    if (-not (Test-Path -Path $currentExe)) {
        Write-Log "K2s exe: '$currentExe' does not exist. Skipping stop." -Console
        return
    }
       
    $stopArgsCall = 'stop'
    $rt = Invoke-Cmd -Executable $currentExe -Arguments $stopArgsCall
    if ( $rt -eq 0 ) {
        Write-Log 'Stop of cluster successfully called'  -Console
    } else {
         throw 'Error: Not possible to stop existing cluster!'
    }

    $nextVersionExe = "$NextVersionKubePath\k2s.exe"
    if (-not (Test-Path -Path $nextVersionExe)) {
        Write-Log "K2s exe: '$nextVersionExe' does not exist. Skipping start." -Console
        return
    }
       
    $startArgsCall = 'start'
    $rt = Invoke-Cmd -Executable $nextVersionExe -Arguments $startArgsCall
    if ( $rt -eq 0 ) {
        Write-Log 'Start of cluster successfully called'
    } else {
        throw 'Error: Not possible to start cluster!'
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
    $texe = "$installFolder\k2s.exe"
    # Check if the k2s exe exists
    if (-not (Test-Path -Path $texe)) {
        Write-Log "K2s exe: '$texe' does not exist. Skipping uninstallation." -Console
        return
    }
    $rt = Invoke-Cmd -Executable $texe -Arguments $argsCall
    if ( $rt -eq 0 ) {
        Write-Log 'Uninstall of cluster successfully called'
    }
    else {
        Write-Log 'Error in calling uninstall on K2s!'
        throw 'Error: Not possible to uninstall old version!'
    }
}

function Get-KubeBinPathGivenKubePath {
    param(
        [string] $KubePathLocal
    )    
    if (Test-Path "$KubePathLocal\bin\kube") {
        return "$KubePathLocal\bin\kube"
    }
    if (Test-Path "$KubePathLocal\bin\exe") {
        return "$KubePathLocal\bin\exe"
    }
    throw "Kube bin path not found in $KubePathLocal"
}

function Wait-ForAPIServerInGivenKubePath {
    param(
        [string] $KubePathLocal
    )
    $controlPlaneVMHostName = Get-ConfigControlPlaneNodeHostname
    $iteration = 0
    $kubeToolsPath = Get-KubeBinPathGivenKubePath -KubePathLocal $KubePathLocal
    while ($true) {
        $iteration++
        # try to apply the flannel resources
        $ErrorActionPreference = 'Continue'
        $result = $(echo yes | &"$kubeToolsPath\kubectl.exe" wait --timeout=60s --for=condition=Ready -n kube-system "pod/kube-apiserver-$($controlPlaneVMHostName.ToLower())" 2>&1)
        $ErrorActionPreference = 'Stop'
        if ($result -match 'condition met') {
            break;
        }
        if ($iteration -eq 10) {
            Write-Log $result -Error
            throw $result
        }
        Start-Sleep 2
    }
    if ($iteration -eq 1) {
        Write-Log 'API Server running, no waiting needed'
    }
    else {
        Write-Log 'API Server now running'
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
        [string] $MasterDiskSize,
        [parameter(Mandatory = $false, HelpMessage = 'Path to install k2s from')]
        [string] $K2sPathToInstallFrom
    )
   
    Write-Log 'Install cluster with the new version' -Console
   
    Write-Log "Using k2sPath: $K2sPathToInstallFrom" -Console
    if ([string]::IsNullOrEmpty($K2sPathToInstallFrom)) {
        $K2sPathToInstallFrom =  Get-KubePath
    }
    # copy executable since else we get ACCESS DENIED
    $texe = "$K2sPathToInstallFrom\k2sx.exe"
    Copy-Item "$K2sPathToInstallFrom\k2s.exe" -Destination $texe -Force -PassThru

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
    Write-Log "Install with arguments: $K2sPathToInstallFrom\k2s $argsCall"
    $rt = Invoke-Cmd -Executable $texe -Arguments $argsCall
    if ( $rt -eq 0 ) {
        Write-Log 'Install of cluster successfully called'
    }
    else {
        Write-Log 'Error in calling install on K2s!'
        # remove temporary executable
        if (Test-Path $texe) {
            Remove-Item $texe -verbose
        }
        throw 'Error: Not possible to install new version!'
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

    if ((Test-Path -Path "$binPath\jq.exe") -ne $true) {
        &$kubePath\smallsetup\windowsnode\downloader\DownloadYamlTools.ps1 -Proxy $Proxy -Deploy
        &$kubePath\smallsetup\windowsnode\publisher\PublishYamlTools.ps1
    }
}

function Get-LinuxVMCores {
    $cores = Get-VMProcessor $controlPlaneName
    return $cores.Count.ToString()
}

function Get-LinuxVMMemory {
    $memory = Get-VMMemory $controlPlaneName
    return [math]::round($memory.Startup / 1GB, 2).ToString() + 'GB'
}

function Get-LinuxVMStorageSize {
    $disksize = Get-VM $controlPlaneName | ForEach-Object { $Vm = $_; $_.HardDrives[0] } | ForEach-Object {
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

    Write-Log "Backup log file to $LogFile" -Console
    
    $oldLogFile = "$($systemDriveLetter)$(Get-LogFilePathPart)"
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
        $restore = "$($systemDriveLetter):\var\log\$file"
        Copy-Item -Path $LogFile -Destination $restore
    }
}

function Get-ProductVersionGivenKubePath {
    param (
        [Parameter(Mandatory = $false)]
        [string]$KubePathLocal = $(throw 'KubePath not specified')        
    )
    return "$(Get-Content -Raw -Path "$KubePathLocal\VERSION")"
}


function Restore-MergeLogFiles {
    Write-Log "Merge all logs to $logFilePath" -Console
    $merge = "$($systemDriveLetter):\var\log\k2supgrade.log"
    $intermediate = "$($systemDriveLetter):\var\log\k2s*.log"

    try {
        # Ensure UTF-8 even for legacy encodings
        $intermediateContent = Get-Content -Path $intermediate
        $logFileContent = Get-Content -Path $logFilePath
        $mergedContent = $intermediateContent + $logFileContent
        $mergedContent | Set-Content -Path $merge -Encoding utf8
    }
    catch {
        Write-Log 'An ERROR occurred in Restore-MergeLogFiles:' -Console
        Write-Log $_.ScriptStackTrace -Console
        Write-Log $_ -Console
        throw $_
    }
}

function Write-RefreshEnvVariablesGivenKubePath {
    param (
        [Parameter(Mandatory = $false)]
        [string]$KubePathLocal = $(throw 'KubePath not specified')        
    )
    Write-Log ' ' -Console
    Write-Log '   Update and or check PATH environment variable for proper usage:' -Console
    Write-Log ' ' -Console
    Write-Log "   Powershell: '$KubePathLocal\smallsetup\helpers\RefreshEnv.ps1'" -Console
    Write-Log "   Command Prompt: '$KubePathLocal\smallsetup\helpers\RefreshEnv.cmd'" -Console
    Write-Log '   Or open new shell' -Console
    Write-Log ' ' -Console
}

function Invoke-UpgradeBackupRestoreHooks {
    param (
        [parameter(Mandatory = $false)]
        [ValidateSet('Backup', 'Restore')]
        [string]$HookType = $(throw 'Hook type not specified'),
        [Parameter(Mandatory = $false)]
        [string]$BackupDir = $(throw 'Back-up directory not specified'),
        [parameter()]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
        [switch] $ShowLogs = $false
    )

    $hooksFilter = "*.$HookType.ps1"

    Write-Log "Executing addons hooks with hook type '$HookType'.."

    $executionCount = 0

    Get-ChildItem -Path $hooksDir -Filter $hooksFilter -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Log "  Executing '$($_.FullName)'.."
        & "$($_.FullName)" -BackupDir $BackupDir -ShowLogs:$ShowLogs
        $executionCount++
    }

    if ($AdditionalHooksDir -ne '') {
        Get-ChildItem -Path $AdditionalHooksDir -Filter $hooksFilter -Force -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Log "  Executing '$($_.FullName)'.."
            & "$($_.FullName)" -BackupDir $BackupDir -ShowLogs:$ShowLogs
            $executionCount++
        }
    }

    if ($executionCount -eq 0) {
        Write-Log 'No back-up/restore hooks found.'
    }
}

function Remove-SetupConfigIfExisting {
    $setupConfigPath = Get-SetupConfigFilePath
    
    if (Test-Path $setupConfigPath) {
        Write-Log "Setup config still existing at '$setupConfigPath', deleting it.."
        Remove-Item -Path $setupConfigPath -Force | Out-Null
    }
}
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

        if(!(Assert-UpgradeOperation))
        {
            return $false
        }

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
            $addonsPath = Join-Path -Path $K2sPathToInstallFrom -ChildPath "addons"
            Restore-Addons -BackupDir $addonsBackupPath -AvoidRestore -Root $addonsPath
        }

        $kubeExeFolder = Get-KubeBinPathGivenKubePath -KubePathLocal $K2sPathToInstallFrom
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
        } else {
            Write-Log "Rolled back to K2s version: $(Get-ProductVersionGivenKubePath -KubePathLocal $K2sPathToInstallFrom) ($K2sPathToInstallFrom)" -Console
        }

        # info on env variables
        Write-RefreshEnvVariablesGivenKubePath -KubePathLocal $K2sPathToInstallFrom
    }
    catch {
        Write-Log 'An ERROR occurred:'
        Write-Log $_.ScriptStackTrace
        Write-Log $_
        throw $_
    }
}

Export-ModuleMember -Function Assert-UpgradeOperation, Enable-ClusterIsRunning, Assert-YamlTools, Export-ClusterResources,
Invoke-ClusterUninstall, Invoke-ClusterInstall, Import-NotNamespacedResources, Import-NamespacedResources, Remove-ExportedClusterResources,
Get-LinuxVMCores, Get-LinuxVMMemory, Get-LinuxVMStorageSize, Get-ClusterInstalledFolder, Backup-LogFile, Restore-LogFile, Restore-MergeLogFiles,
Invoke-UpgradeBackupRestoreHooks, Remove-SetupConfigIfExisting, Get-TempPath, Wait-ForAPIServerInGivenKubePath, Get-KubeBinPathGivenKubePath,
Write-RefreshEnvVariablesGivenKubePath, Get-ProductVersionGivenKubePath, PrepareClusterUpgrade, PerformClusterUpgrade
