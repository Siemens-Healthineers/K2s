# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT


$configModule = "$PSScriptRoot\..\..\k2s.infra.module\config\config.module.psm1"
$logModule = "$PSScriptRoot\..\..\k2s.infra.module\log\log.module.psm1"
$pathModule = "$PSScriptRoot\..\..\k2s.infra.module\path\path.module.psm1"
$hooksModule = "$PSScriptRoot\..\..\k2s.infra.module\hooks\hooks.module.psm1"
$vmModule = "$PSScriptRoot\..\..\k2s.node.module\linuxnode\vm\vm.module.psm1"
$vmNodeModule = "$PSScriptRoot\..\..\k2s.node.module\vmnode\vmnode.module.psm1"
$kubeToolsModule = "$PSScriptRoot\..\..\k2s.node.module\windowsnode\downloader\artifacts\kube-tools\kube-tools.module.psm1"
$imageModule = "$PSScriptRoot\..\image\image.module.psm1"

Import-Module $configModule, $logModule, $pathModule, $vmModule, $hooksModule, $kubeToolsModule, $imageModule, $vmNodeModule

$kubePath = Get-KubePath
$kubeConfigDir = Get-ConfiguredKubeConfigDir
$setupConfigRoot = Get-RootConfigk2s

$kubeletConfigDir = Get-KubeletConfigDir
$joinConfigurationFilePath = "$kubePath\cfg\kubeadm\joinwindowsnode.yaml"
$kubernetesImagesJson = Get-KubernetesImagesFilePath
$kubeToolsPath = Get-KubeToolsPath

function Add-K8sContext {
    # set context on windows host (add to existing contexts)
    Write-Log 'Reset kubectl config'
    $env:KUBECONFIG = $kubeConfigDir + '\config'
    if (!(Test-Path $kubeConfigDir)) {
        mkdir $kubeConfigDir -Force | Out-Null
    }
    if (!(Test-Path $env:KUBECONFIG)) {
        $source = "$kubePath\config"
        $target = $kubeConfigDir + '\config'
        Copy-Item $source -Destination $target -Force | Out-Null
    }
    else {
        #kubectl config view
        &"$kubeToolsPath\kubectl.exe" config unset contexts.kubernetes-admin@kubernetes
        &"$kubeToolsPath\kubectl.exe" config unset clusters.kubernetes
        &"$kubeToolsPath\kubectl.exe" config unset users.kubernetes-admin
        Write-Log 'Adding new context and new cluster to Kubernetes config...'
        $source = $kubeConfigDir + '\config'
        $target = $kubeConfigDir + '\config_backup'
        Copy-Item $source -Destination $target -Force | Out-Null
        $env:KUBECONFIG = "$kubeConfigDir\config;$kubePath\config"
        #kubectl config view
        $target1 = $kubeConfigDir + '\config_new'
        Remove-Item -Path $target1 -Force -ErrorAction SilentlyContinue
        &"$kubeToolsPath\kubectl.exe" config view --raw > $target1
        $target2 = $kubeConfigDir + '\config'
        Remove-Item -Path $target2 -Force -ErrorAction SilentlyContinue
        Move-Item -Path $target1 -Destination $target2 -Force
    }
    &"$kubeToolsPath\kubectl.exe" config use-context kubernetes-admin@kubernetes
    Write-Log 'Config from user directory:'
    $env:KUBECONFIG = ''
    &"$kubeToolsPath\kubectl.exe" config view
}

<#
    NOTE: Import module is necessary as this function runs as independent process
    Wait until both the master and the worker node are ready, then kill the kubeadm process which waits
    for the TLS bootstrap.
    This shortens the waiting time, as we have no real TLS bootstrap:
     - The config file got copied from the master, so the kubelet
       starts and joins without doing a full TLS bootstrap
     - As a consequence, the kubeadm join waits forever and does not detect
       the finished joining
#>
function Wait-ForNodesReady {
    param(
        [Parameter()]
        [String]
        $controlPlaneHostName
    )
    # force import path module since this is executed in a script block
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep 2
        #Write-Output "Checking for node $env:COMPUTERNAME..."
        # using is used because this function is executed in script block in Join-WindowsNode.
        $nodes = $(&"$using:kubeToolsPath\kubectl.exe" get nodes)
        #Write-Output "$i WaitForJoin: $nodes"

        $nodefound = $nodes | Select-String -Pattern "$env:COMPUTERNAME\s*Ready"
        if ( $nodefound ) {
            Write-Output "Node found: $nodefound"
            $masterReady = $nodes | Select-String -Pattern "$controlPlaneHostName\s*Ready"
            if ($masterReady) {
                Write-Output "Master also ready, stopping 'kubeadm join'"
                Stop-Process -Name kubeadm -Force -ErrorAction SilentlyContinue
                break
            }
            else {
                Write-Output 'Master not ready yet, keep waiting...'
            }
        }
    }
}

<#
Join the windows node with linux control plane node
#>
function Join-WindowsNode {
    Param(
        [string]$CommandForJoining = $(throw 'Argument missing: CommandForJoining'),
        [string] $WorkerNodeNumber = $(throw 'Argument missing: WorkerNodeNumber')
    )

    # join node if necessary
    $nodefound = &"$kubeToolsPath\kubectl.exe" get nodes | Select-String -Pattern $env:COMPUTERNAME -SimpleMatch
    if ( !($nodefound) ) {

        # copy kubeadmin to c:
        $tempKubeadmDirectory = $(Get-SystemDriveLetter) + ':\k'
        $bPathAvailable = Test-Path -Path $tempKubeadmDirectory
        if ( !$bPathAvailable ) { mkdir -Force $tempKubeadmDirectory | Out-Null }
        Copy-Item -Path "$kubePath\bin\exe\kubeadm.exe" -Destination $tempKubeadmDirectory -Force

        Write-Log 'Add kubeadm to firewall rules'
        New-NetFirewallRule -DisplayName 'Allow temp Kubeadm' -Group 'k2s' -Direction Inbound -Action Allow -Program "$tempKubeadmDirectory\kubeadm.exe" -Enabled True | Out-Null
        #Below rule is not neccessary but adding in case we perform subsequent operations.
        New-NetFirewallRule -DisplayName 'Allow Kubeadm' -Group 'k2s' -Direction Inbound -Action Allow -Program "$kubePath\bin\exe\kubeadm.exe" -Enabled True | Out-Null

        Write-Log "Host $env:COMPUTERNAME not yet available as worker node."

        & "$tempKubeadmDirectory\kubeadm.exe" reset -f 2>&1 | Write-Log
        Get-ChildItem -Path $kubeletConfigDir -Force -Recurse -Attributes Reparsepoint -ErrorAction 'silentlycontinue' | % { $n = $_.FullName.Trim('\'); fsutil reparsepoint delete "$n" }
        Remove-Item -Path "$kubeletConfigDir\etc" -Force -Recurse -ErrorAction SilentlyContinue
        New-Item -Path "$kubeletConfigDir\etc" -ItemType SymbolicLink -Value "$(Get-SystemDriveLetter):\etc" | Out-Null
        # get join command
        # Remove-Job -Name JoinK8sJob -Force -ErrorAction SilentlyContinue
        Write-Log 'Build join command ..'

        $cmdjoin = $CommandForJoining | Select-String -Pattern 'kubeadm join' -CaseSensitive -SimpleMatch
        $cmdjoin.Line = $cmdjoin.Line.replace("`n", '').replace("`r", '')

        $searchPattern = 'kubeadm join (?<api>[^\s]*) --token (?<token>[^\s]*) --discovery-token-ca-cert-hash (?<hash>[^\s]*)'
        $patternSearchResult = $cmdjoin.Line | Select-String -Pattern $searchPattern

        if (($null -eq $patternSearchResult.Matches) -or ($patternSearchResult.Matches.Count -ne 1) -or ($patternSearchResult.Matches.Groups.Count -ne (3 + 1))) {
            $errorMessage = "Could not find the api server endpoint and/or the token and/or the hash from the return value of the command '$tokenCreationCommand'`n" +
            "  - Command return value: '$($cmdjoin.Line)'`n" +
            "  - Search pattern: '$searchPattern'`n"
            throw $errorMessage
        }

        $apiServerEndpoint = $patternSearchResult.Matches.Groups[1].Value
        $token = $patternSearchResult.Matches.Groups[2].Value
        $hash = $patternSearchResult.Matches.Groups[3].Value
        $caCertFilePath = "$(Get-SystemDriveLetter):\etc\kubernetes\pki\ca.crt"
        $windowsNodeIpAddress = Get-ConfiguredClusterCIDRNextHop -WorkerNodeNumber $WorkerNodeNumber

        Write-Log 'Create config file for join command'
        $joinConfigurationTemplateFilePath = "$kubePath\cfg\kubeadm\joinwindowsnode.template.yaml"

        $content = (Get-Content -path $joinConfigurationTemplateFilePath -Raw)
        $content.Replace('__CA_CERT__', $caCertFilePath).Replace('__API__', $apiServerEndpoint).Replace('__TOKEN__', $token).Replace('__SHA__', $hash).Replace('__NODE_IP__', $windowsNodeIpAddress) | Set-Content -Path "$joinConfigurationFilePath"

        $joinCommand = '.\' + "kubeadm join $apiServerEndpoint" + ' --node-name ' + $env:COMPUTERNAME + ' --ignore-preflight-errors IsPrivilegedUser' + " --config `"$joinConfigurationFilePath`""

        Write-Log $joinCommand

        $controlPlaneHostName = Get-ConfigControlPlaneNodeHostname
        $job = Invoke-Expression "Start-Job -ScriptBlock `${Function:Wait-ForNodesReady} -ArgumentList $controlPlaneHostName"
        Set-Location $tempKubeadmDirectory
        Invoke-Expression $joinCommand 2>&1 | Write-Log
        Set-Location ..\..

        # print the output of the WaitForJoin.ps1
        Receive-Job $job
        $job | Stop-Job

        # delete path if was created
        Remove-Item -Path $tempKubeadmDirectory\kubeadm.exe
        if ( !$bPathAvailable ) { Remove-Item -Path $tempKubeadmDirectory }

        # check success in joining
        $nodefound = &"$kubeToolsPath\kubectl.exe" get nodes | Select-String -Pattern $env:COMPUTERNAME -SimpleMatch
        if ( !($nodefound) ) {
            &"$kubeToolsPath\kubectl.exe" get nodes
            throw 'Joining the windows node failed'
        }

        Write-Log "Joining node $env:COMPUTERNAME to cluster is done."
    }
    else {
        Write-Log "Host $env:COMPUTERNAME already available as node !"
    }

    # check success in creating kubelet config file
    $kubeletConfig = "$kubeletConfigDir\config.yaml"
    Write-Log "kubelect config under: $kubeletConfig"
    if (! (Test-Path $kubeletConfig)) {
        throw "Expected file not created: $kubeletConfig"
    }
    if (! (Get-Content $kubeletConfig | Select-String -Pattern 'KubeletConfiguration' -SimpleMatch)) {
        throw "Wrong content in $kubeletConfig, aborting"
    }
    $kubeletEnv = "$kubeletConfigDir\kubeadm-flags.env"
    if (! (Test-Path $kubeletEnv)) {
        throw "Expected file not created: $kubeletEnv"
    }

    # mark nodes as worker
    Write-Log 'Labeling windows node as worker node'
    &"$kubeToolsPath\kubectl.exe" label nodes $env:computername.ToLower() kubernetes.io/role=worker --overwrite | Out-Null
}

function Add-ClusterDnsNameToHost {
    param([string]$DesiredIP = ''
        , [string]$Hostname = 'k2s.cluster.local'
        , [bool]$CheckHostnameOnly = $false)

    # check ip
    if ($DesiredIP -eq '') {
        $DesiredIP = Get-ConfiguredIPControlPlane
    }

    # Adds entry to the hosts file.
    $hostsFilePath = "$($Env:WinDir)\system32\Drivers\etc\hosts"
    $hostsFile = Get-Content $hostsFilePath

    Write-Log "Add $desiredIP for $Hostname to hosts file"

    $escapedHostname = [Regex]::Escape($Hostname)
    $patternToMatch = If ($CheckHostnameOnly) { ".*\s+$escapedHostname.*" } Else { ".*$DesiredIP\s+$escapedHostname.*" }
    If (($hostsFile) -match $patternToMatch) {
        Write-Log $desiredIP.PadRight(20, ' '), "$Hostname - not adding; already in hosts file"
    }
    Else {
        Write-Log $desiredIP.PadRight(20, ' '), "$Hostname - adding to hosts file... "
        Add-Content -Encoding UTF8 $hostsFilePath ("$DesiredIP".PadRight(20, ' ') + "$Hostname")
        Write-Log ' done'
    }
}

function Set-KubeletDiskPressure {
    # set new limits for the windows node for disk pressure
    # kubelet is running now (caused by joining the windows host to the cluster), so we stop it. Will be restarted in start-up sequence.
    Stop-Service kubelet
    $kubeletconfig = "$kubeletConfigDir\config.yaml"
    Write-Log "using kubelet file: $kubeletconfig"
    $content = Get-Content "$kubeletconfig"
    $content | ForEach-Object { $_ -replace 'evictionPressureTransitionPeriod:',
        "evictionHard:`r`n  nodefs.available: 8Gi`r`n  imagefs.available: 8Gi`r`nevictionPressureTransitionPeriod:" } |
    Set-Content "$kubeletconfig"
}

function Initialize-KubernetesCluster {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [string] $WorkerNodeNumber = $(throw 'Argument missing: WorkerNodeNumber')
    )
    Copy-KubeConfigFromControlPlaneNode
    Add-K8sContext
    Invoke-Hook -HookName 'AfterVmInitialized' -AdditionalHooksDir $AdditionalHooksDir

    # try to join host windows node
    Write-Log 'starting the join process'
    
    $joinCommand = New-JoinCommand
    Join-WindowsNode -CommandForJoining $joinCommand -WorkerNodeNumber $WorkerNodeNumber

    Set-KubeletDiskPressure

    # show results
    Write-Log "Current state of kubernetes nodes:`n"
    Start-Sleep 2
    &"$kubeToolsPath\kubectl.exe" get nodes -o wide

    Write-Log "Collecting kubernetes images and storing them to $kubernetesImagesJson."
    Write-KubernetesImagesIntoJson
}

function Uninstall-Cluster {
    Remove-Item -Path "$joinConfigurationFilePath" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubernetesImagesJson" -Force -ErrorAction SilentlyContinue
}

function Initialize-VMKubernetesCluster {
    Param(
        [parameter(Mandatory = $true, HelpMessage = 'Windows VM Name to use')]
        [string] $VMName,
        [parameter(Mandatory = $false, HelpMessage = 'IP address of the VM')]
        [string] $IpAddress,
        [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
        [string] $Proxy,
        [parameter(Mandatory = $false, HelpMessage = 'Kubernetes version to use')]
        [string] $KubernetesVersion,
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = ''
    )

    # TODO accept from user or use default
    $vmPwd = Get-DefaultTempPwd
    $vmSession = Open-RemoteSession -VmName $VMName -VmPwd $vmPwd

    # Establish communication and copy kubeconfig from control plane
    Invoke-Command -Session $vmSession {
        Set-Location "$env:SystemDrive\k"
        Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

        Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1
        Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.node.module\k2s.node.module.psm1
        Initialize-Logging -Nested:$true
        Wait-ForSSHConnectionToLinuxVMViaSshKey -Nested:$true
        Copy-KubeConfigFromControlPlaneNode -Nested:$true
    }

    Save-ControlPlaneNodeHostnameIntoWinVM $vmSession

    Copy-KubeConfigFromControlPlaneNode

    Install-KubectlOnHost $KubernetesVersion $Proxy

    Add-K8sContext

    Invoke-Hook -HookName 'AfterVmInitialized' -AdditionalHooksDir $AdditionalHooksDir

    Write-Log 'Joining Nodes' -Console

    Join-VMWindowsNode $vmSession

    Set-DiskPressureLimitsOnWindowsNode $vmSession # TODO: check if this is necessary

    Add-IPsToHostsFiles $vmSession $VMName $IpAddress

    Write-K8sNodesStatus

    Enable-SSHRemotingViaSSHKeyToWinNode $vmSession $Proxy

    $adminWinNode = Get-DefaultWinVMName
    $windowsVMKey = Get-DefaultWinVMKey
    # Initiate first time ssh to establish connection over key for subsequent operations
    ssh.exe -n -o StrictHostKeyChecking=no -i $windowsVMKey $adminWinNode hostname 2> $null

    Disable-PasswordAuthenticationToWinNode

    Write-Log "Collecting kubernetes images and storing them to $(Get-KubernetesImagesFilePath)."
    Write-KubernetesImagesIntoJson -WorkerVM $true
}

function Install-KubectlOnHost($KubernetesVersion, $Proxy) {
    $previousKubernetesVersion = Get-ConfigInstalledKubernetesVersion

    $kubeBinExePath = Get-KubeToolsPath

    if (!(Test-Path "$kubeBinExePath")) {
        New-Item -Path $kubeBinExePath -ItemType Directory | Out-Null
    }

    if (!(Test-Path "$kubeBinExePath\kubectl.exe") -or ($previousKubernetesVersion -ne $KubernetesVersion)) {
        Invoke-DownloadKubectl -Destination "$kubeBinExePath\kubectl.exe" -KubernetesVersion $KubernetesVersion -Proxy "$Proxy"
    }
}

function Save-ControlPlaneNodeHostnameIntoWinVM($vmSession) {
    $hostname = Get-ConfigControlPlaneNodeHostname
    Write-Log "Saving VM hostname '$hostname' into Windows node ..."
    Invoke-Command -Session $vmSession {
        Set-Location "$env:SystemDrive\k"
        Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

        Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1
        Initialize-Logging -Nested:$true

        Set-ConfigControlPlaneNodeHostname $($using:hostname)
    }
    Write-Log '  done.'
}

function Join-VMWindowsNode($vmSession, $workerNodeNumber) {
    Write-Log 'Joining Windows node ...'

    $ErrorActionPreference = 'Continue'

    $joinCommand = New-JoinCommand

    Invoke-Command -Session $vmSession {
        Set-Location "$env:SystemDrive\k"
        Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

        # disable IPv6 completely
        Get-NetAdapterBinding -ComponentID ms_tcpip6 | ForEach-Object {
            Disable-NetAdapterBinding -Name $_.Name -ComponentID ms_tcpip6
        }

        Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1
        Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.node.module\k2s.node.module.psm1
        Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1
        Initialize-Logging -Nested:$true

        Join-WindowsNode -CommandForJoining $using:joinCommand -WorkerNodeNumber $using:workerNodeNumber
    }

    $ErrorActionPreference = 'Stop'

    Write-Log 'Windows node joined.'
}

function New-JoinCommand {
    $tokenCreationCommand = 'sudo kubeadm token create --print-join-command'
    $joinCommand = (Invoke-CmdOnControlPlaneViaSSHKey "$tokenCreationCommand").Output 2>&1
    return $joinCommand
}

function Set-DiskPressureLimitsOnWindowsNode($vmSession) {
    Write-Log 'Setting disk pressure limits on Windows node ...'

    Invoke-Command -Session $vmSession {
        Set-Location "$env:SystemDrive\k"
        Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

        Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1
        Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.node.module\k2s.node.module.psm1
        Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1
        Initialize-Logging -Nested:$true

        Set-KubeletDiskPressure
    }

    Write-Log 'Disk pressure limits on Windows node set.'
}

function Add-IPsToHostsFiles($vmSession, $VMName, $IpAddress) {
    Write-Log 'Adding IPs to hosts files ...'

    Add-ClusterDnsNameToHost -DesiredIP $IpAddress -Hostname $VMName

    Invoke-Command -Session $vmSession {
        Set-Location "$env:SystemDrive\k"
        Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

        Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1
        Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.node.module\k2s.node.module.psm1
        Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1
        Initialize-Logging -Nested:$true

        Add-ClusterDnsNameToHost -Hostname 'k2s.cluster.local'
    }

    Write-Log 'IPs added to hosts files.'
}

function Write-K8sNodesStatus {
    $retryIteration = 0
    $ErrorActionPreference = 'Continue'
    while ($true) {
        $kubeToolsPath = Get-KubeToolsPath
        #Check whether node information is available from the cluster
        &"$kubeToolsPath\kubectl.exe" get nodes 2>$null | Out-Null
        if ($?) {
            Write-Log 'Current state of kubernetes nodes:'
            &"$kubeToolsPath\kubectl.exe" get nodes -o wide
            break
        }
        else {
            Write-Log "Iteration: $retryIteration Node status not available yet, retrying in a moment..."
            Start-Sleep -Seconds 5
        }

        if ($retryIteration -eq 10) {
            throw 'Unable to get cluster node status information'
        }
        $retryIteration++
    }
    $ErrorActionPreference = 'Stop'
}

Export-ModuleMember Initialize-KubernetesCluster,
Uninstall-Cluster, Set-KubeletDiskPressure,
Join-WindowsNode, Join-VMWindowsNode, Add-K8sContext,
Add-ClusterDnsNameToHost, Initialize-VMKubernetesCluster,
Set-DiskPressureLimitsOnWindowsNode, Add-IPsToHostsFiles,
Write-K8sNodesStatus