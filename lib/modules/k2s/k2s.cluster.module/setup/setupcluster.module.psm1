# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT


$configModule = "$PSScriptRoot\..\..\k2s.infra.module\config\config.module.psm1"
$logModule = "$PSScriptRoot\..\..\k2s.infra.module\log\log.module.psm1"
$pathModule = "$PSScriptRoot\..\..\k2s.infra.module\path\path.module.psm1"
$hooksModule = "$PSScriptRoot\..\..\k2s.infra.module\hooks\hooks.module.psm1"
$vmModule = "$PSScriptRoot\..\..\k2s.node.module\linuxnode\vm\vm.module.psm1"
$kubeToolsModule = "$PSScriptRoot\..\..\k2s.node.module\windowsnode\downloader\artifacts\kube-tools\kube-tools.module.psm1"
$imageModule = "$PSScriptRoot\..\image\image.module.psm1"

Import-Module $configModule, $logModule, $pathModule, $vmModule, $hooksModule, $kubeToolsModule, $imageModule

$kubePath = Get-KubePath
$kubeConfigDir = Get-ConfiguredKubeConfigDir
$setupConfigRoot = Get-RootConfigk2s

$kubeletConfigDir = Get-KubeletConfigDir
$joinConfigurationFilePath = "$kubePath\cfg\kubeadm\joinwindowsnode.yaml"
$kubernetesImagesJson = Get-KubernetesImagesFilePath

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
        kubectl config unset contexts.kubernetes-admin@kubernetes
        kubectl config unset clusters.kubernetes
        kubectl config unset users.kubernetes-admin
        Write-Log 'Adding new context and new cluster to Kubernetes config...'
        $source = $kubeConfigDir + '\config'
        $target = $kubeConfigDir + '\config_backup'
        Copy-Item $source -Destination $target -Force | Out-Null
        $env:KUBECONFIG = "$kubeConfigDir\config;$kubePath\config"
        #kubectl config view
        $target1 = $kubeConfigDir + '\config_new'
        Remove-Item -Path $target1 -Force -ErrorAction SilentlyContinue
        kubectl config view --raw > $target1
        $target2 = $kubeConfigDir + '\config'
        Remove-Item -Path $target2 -Force -ErrorAction SilentlyContinue
        Move-Item -Path $target1 -Destination $target2 -Force
    }
    kubectl config use-context kubernetes-admin@kubernetes
    Write-Log 'Config from user directory:'
    $env:KUBECONFIG = ''
    kubectl config view
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
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep 2
        #Write-Output "Checking for node $env:COMPUTERNAME..."

        $nodes = $(kubectl get nodes)
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
        [Parameter(HelpMessage = 'When executing ssh.exe in nested environment[host=>VM=>VM], -n flag should not be used.')]
        [switch]$Nested = $false
    )

    # join node if necessary
    $nodefound = kubectl get nodes | Select-String -Pattern $env:COMPUTERNAME -SimpleMatch
    if ( !($nodefound) ) {

        Write-Log 'Add kubeadm to firewall rules'
        New-NetFirewallRule -DisplayName 'Allow Kubeadm' -Group 'k2s' -Direction Inbound -Action Allow -Program "$kubePath\bin\exe\kubeadm.exe" -Enabled True | Out-Null

        Write-Log "Host $env:COMPUTERNAME not yet available as worker node."

        & "$kubePath/bin/exe/kubeadm.exe" reset -f 2>&1 | Write-Log
        Get-ChildItem -Path $kubeletConfigDir -Force -Recurse -Attributes Reparsepoint -ErrorAction 'silentlycontinue' | % { $n = $_.FullName.Trim('\'); fsutil reparsepoint delete "$n" }
        Remove-Item -Path "$kubeletConfigDir\etc" -Force -Recurse -ErrorAction SilentlyContinue
        New-Item -Path "$kubeletConfigDir\etc" -ItemType SymbolicLink -Value "$(Get-SystemDriveLetter):\etc" | Out-Null
        # get join command
        # Remove-Job -Name JoinK8sJob -Force -ErrorAction SilentlyContinue
        Write-Log 'Build join command ..'

        $tokenCreationCommand = 'sudo kubeadm token create --print-join-command'
        $cmdjoin = Invoke-CmdOnControlPlaneViaSSHKey "$tokenCreationCommand" -NoLog 2>&1 | Select-String -Pattern 'kubeadm join' -CaseSensitive -SimpleMatch
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
        $windowsNodeIpAddress = $setupConfigRoot.psobject.properties['cbr0'].value

        Write-Log 'Create config file for join command'
        $joinConfigurationTemplateFilePath = "$kubePath\cfg\kubeadm\joinwindowsnode.template.yaml"

        $content = (Get-Content -path $joinConfigurationTemplateFilePath -Raw)
        $content.Replace('__CA_CERT__', $caCertFilePath).Replace('__API__', $apiServerEndpoint).Replace('__TOKEN__', $token).Replace('__SHA__', $hash).Replace('__NODE_IP__', $windowsNodeIpAddress) | Set-Content -Path "$joinConfigurationFilePath"

        $joinCommand = '.\' + "kubeadm join $apiServerEndpoint" + ' --node-name ' + $env:COMPUTERNAME + ' --ignore-preflight-errors IsPrivilegedUser' + " --config `"$joinConfigurationFilePath`""

        Write-Log $joinCommand

        # $job = Start-Job -Name JoinK8sJob -ScriptBlock { Invoke-Expression $cmdjoin }
        # Write-Log $job
        # $job | Receive-Job -Keep
        $controlPlaneHostName = Get-ConfigControlPlaneNodeHostname
        $job = Invoke-Expression "Start-Job -ScriptBlock `${Function:Wait-ForNodesReady} -ArgumentList $controlPlaneHostName"
        Set-Location "$kubePath\bin\exe"
        Invoke-Expression $joinCommand 2>&1 | Write-Log
        Set-Location ..\..

        # print the output of the WaitForJoin.ps1
        Receive-Job $job
        $job | Stop-Job

        # check success in joining
        $nodefound = kubectl get nodes | Select-String -Pattern $env:COMPUTERNAME -SimpleMatch
        if ( !($nodefound) ) {
            kubectl get nodes
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
    kubectl label nodes $env:computername.ToLower() kubernetes.io/role=worker --overwrite | Out-Null
}

function Add-ClusterDnsNameToHost {
    param([string]$DesiredIP = ''
        , [string]$Hostname = 'k2s.cluster.net'
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

<#
.SYNOPSIS
Write refresh info.

.DESCRIPTION
Write information about refersh of env variables
#>
function Write-RefreshEnvVariables {
    Write-Log ' ' -Console
    Write-Log '   Update PATH environment variable for proper usage:' -Console
    Write-Log ' ' -Console
    Write-Log "   Powershell: '$kubePath\smallsetup\helpers\RefreshEnv.ps1'" -Console
    Write-Log "   Command Prompt: '$kubePath\smallsetup\helpers\RefreshEnv.cmd'" -Console
    Write-Log '   Or open new shell' -Console
    Write-Log ' ' -Console
}

function Initialize-KubernetesCluster {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = ''
    )
    Copy-KubeConfigFromControlPlaneNode
    Add-K8sContext
    Invoke-Hook -HookName 'AfterVmInitialized' -AdditionalHooksDir $AdditionalHooksDir

    # try to join host windows node
    Write-Log 'starting the join process'
    Join-WindowsNode

    # set new limits for the windows node for disk pressure
    # kubelet is running now (caused by JoinWindowsHost.ps1), so we stop it. Will be restarted in StartK8s.ps1.
    Stop-Service kubelet
    Write-Log 'using kubelet file:' + "$kubeletConfigDir\config.yaml"
    $content = Get-Content "$kubeletConfigDir\config.yaml"
    $content | ForEach-Object { $_ -replace 'evictionPressureTransitionPeriod:',
        "evictionHard:`r`n  nodefs.available: 8Gi`r`n  imagefs.available: 8Gi`r`nevictionPressureTransitionPeriod:" } |
    Set-Content "$kubeletConfigDir\config.yaml"

    # add ip to hosts file
    Add-ClusterDnsNameToHost

    # show results
    Write-Log "Current state of kubernetes nodes:`n"
    Start-Sleep 2
    kubectl get nodes -o wide

    Write-Log "Collecting kubernetes images and storing them to $kubernetesImagesJson."
    Write-KubernetesImagesIntoJson
}

function Uninstall-Cluster {
    if ($global:PurgeOnUninstall) {
        Remove-Item -Path "$joinConfigurationFilePath" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$kubernetesImagesJson" -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember Initialize-KubernetesCluster, Write-RefreshEnvVariables, Uninstall-Cluster