# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
# SPDX-License-Identifier: MIT


$configModule = "$PSScriptRoot\..\..\k2s.infra.module\config\config.module.psm1"
$logModule = "$PSScriptRoot\..\..\k2s.infra.module\log\log.module.psm1"
$pathModule = "$PSScriptRoot\..\..\k2s.infra.module\path\path.module.psm1"
$hooksModule = "$PSScriptRoot\..\..\k2s.infra.module\hooks\hooks.module.psm1"
$vmModule = "$PSScriptRoot\..\..\k2s.node.module\linuxnode\vm\vm.module.psm1"
$vmNodeModule = "$PSScriptRoot\..\..\k2s.node.module\vmnode\vmnode.module.psm1"
$kubeToolsModule = "$PSScriptRoot\..\..\k2s.node.module\windowsnode\downloader\artifacts\kube-tools\kube-tools.module.psm1"
$imageModule = "$PSScriptRoot\..\image\image.module.psm1"
$k8sApiModule = "$PSScriptRoot\..\k8s-api\k8s-api.module.psm1"

Import-Module $configModule, $logModule, $pathModule, $vmModule, $hooksModule, $kubeToolsModule, $imageModule, $vmNodeModule, $k8sApiModule

$kubePath = Get-KubePath
$kubeConfigDir = Get-ConfiguredKubeConfigDir

$kubeletConfigDir = Get-KubeletConfigDir
$joinConfigurationFilePath = "$kubePath\cfg\kubeadm\joinnode.yaml"
$kubernetesImagesJson = Get-KubernetesImagesFilePath
$kubeToolsPath = Get-KubeToolsPath

function Add-K8sContext {
    # set context on windows host (add to existing contexts)
    Write-Log 'Reset kubectl config'
    $env:KUBECONFIG = $kubeConfigDir + '\config'
    if (!(Test-Path $kubeConfigDir)) {
        mkdir $kubeConfigDir -Force | Out-Null
    }

    $clusterName = Get-InstalledClusterName
    $userName = 'kubernetes-admin'

    if (!(Test-Path $env:KUBECONFIG)) {
        $source = "$kubePath\config"
        $target = $kubeConfigDir + '\config'
        Copy-Item $source -Destination $target -Force | Out-Null
    }
    else {
        #kubectl config view
        &"$kubeToolsPath\kubectl.exe" config unset "contexts.$userName@$clusterName"
        &"$kubeToolsPath\kubectl.exe" config unset "clusters.$clusterName"
        &"$kubeToolsPath\kubectl.exe" config unset "users.$userName"
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
    &"$kubeToolsPath\kubectl.exe" config use-context "$userName@$clusterName"
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
.SYNOPSIS
Patches the Windows node PodCIDR to match the expected value configured in config.json.

.DESCRIPTION
After a Windows node joins the cluster, Kubernetes controller-manager automatically allocates
a PodCIDR from the podSubnet range. However, K2s expects a specific PodCIDR (podNetworkWorkerCIDR)
that Flannel and other networking components are configured to use. This function patches the
node's PodCIDR to match the expected value.

.PARAMETER NodeName
The name of the Windows node to patch.

.PARAMETER PodSubnetworkNumber
The pod subnetwork number (e.g., '1' for 172.20.1.0/24).
#>
function Set-WindowsNodePodCIDR {
    Param(
        [string] $NodeName = $(throw 'Argument missing: NodeName'),
        [string] $PodSubnetworkNumber = $(throw 'Argument missing: PodSubnetworkNumber')
    )

    Write-Log "Patching Windows node '$NodeName' PodCIDR to match expected value"

    # Get expected PodCIDR from config.json
    $setupConfigRoot = Get-RootConfigk2s
    $clusterCIDRWorkerTemplate = $setupConfigRoot.psobject.properties['podNetworkWorkerCIDR_2'].value
    $expectedPodCIDR = $clusterCIDRWorkerTemplate.Replace('X', $PodSubnetworkNumber)

    # Get current PodCIDR from node
    $currentPodCIDR = &"$kubeToolsPath\kubectl.exe" get nodes $NodeName -o jsonpath="{.spec.podCIDR}" 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        Write-Log "[WARN] Failed to get current PodCIDR for node '$NodeName': $currentPodCIDR" -Console
        return
    }

    Write-Log "Current PodCIDR: $currentPodCIDR"
    Write-Log "Expected PodCIDR: $expectedPodCIDR"

    if ($currentPodCIDR -eq $expectedPodCIDR) {
        Write-Log "PodCIDR already matches expected value, no patching needed"
        return
    }

    # Patch the node PodCIDR
    Write-Log "Patching node '$NodeName' PodCIDR from '$currentPodCIDR' to '$expectedPodCIDR'"
    
    # Build patch JSON and write to temp file to avoid PowerShell JSON quoting issues
    $patchObject = @{
        spec = @{
            podCIDR = $expectedPodCIDR
            podCIDRs = @($expectedPodCIDR)
        }
    }
    $patchJson = $patchObject | ConvertTo-Json -Compress -Depth 10
    Write-Log "Patch JSON: $patchJson"
    
    $patchFile = [System.IO.Path]::GetTempFileName()
    try {
        # Write JSON without BOM (Out-File -Encoding utf8 adds BOM in Windows PowerShell, corrupting JSON)
        [System.IO.File]::WriteAllText($patchFile, $patchJson, [System.Text.UTF8Encoding]::new($false))
        
        # Use kubectl directly with retry logic for transient failures
        $kubeToolsPath = Get-KubeToolsPath
        $maxRetries = 3
        $retryDelay = 2
        $patchSuccess = $false
        
        for ($retry = 1; $retry -le $maxRetries; $retry++) {
            $patchOutput = &"$kubeToolsPath\kubectl.exe" patch node $NodeName --type=merge --patch-file=$patchFile 2>&1
            $patchResult = [pscustomobject]@{ Success = ($LASTEXITCODE -eq 0); Output = $patchOutput }
            
            if ($patchResult.Success) {
                $patchSuccess = $true
                break
            }
            
            Write-Log "[WARN] Patch attempt $retry/$maxRetries failed: $($patchResult.Output)"
            
            if ($retry -lt $maxRetries) {
                Write-Log "Retrying in $retryDelay seconds..."
                Start-Sleep -Seconds $retryDelay
            }
        }
    }
    finally {
        Remove-Item -Path $patchFile -Force -ErrorAction SilentlyContinue
    }
    
    if (-not $patchSuccess) {
        Write-Log "[ERROR] Failed to patch PodCIDR for node '$NodeName' after $maxRetries attempts: $($patchResult.Output)" -Console
        throw "Failed to patch Windows node PodCIDR. Flannel may not work correctly."
    }

    # Verify the patch was successful
    $verifyPodCIDR = &"$kubeToolsPath\kubectl.exe" get nodes $NodeName -o jsonpath="{.spec.podCIDR}" 2>&1
    
    if ($verifyPodCIDR -eq $expectedPodCIDR) {
        Write-Log "Successfully patched node PodCIDR to '$expectedPodCIDR'" -Console
    }
    else {
        Write-Log "[WARN] PodCIDR patch may not have applied correctly. Expected: $expectedPodCIDR, Got: $verifyPodCIDR" -Console
    }
}

<#
Join the windows node with linux control plane node
#>
function Join-WindowsNode {
    Param(
        [string]$CommandForJoining = $(throw 'Argument missing: CommandForJoining'),
        [string] $PodSubnetworkNumber = $(throw 'Argument missing: PodSubnetworkNumber')
    )

    # join node if necessary
    $nodefound = &"$kubeToolsPath\kubectl.exe" get nodes | Select-String -Pattern $env:COMPUTERNAME -SimpleMatch
    if ( !($nodefound) ) {

        # copy kubeadmin to c:
        $tempKubeadmDirectory = $(Get-SystemDriveLetter) + ':\k'
        $bPathAvailable = Test-Path -Path $tempKubeadmDirectory
        if ( !$bPathAvailable ) { mkdir -Force $tempKubeadmDirectory | Out-Null }
        Copy-Item -Path "$kubeToolsPath\kubeadm.exe" -Destination $tempKubeadmDirectory -Force

        Write-Log 'Add kubeadm to firewall rules'
        $tempRuleName = 'Allow temp Kubeadm'
        New-NetFirewallRule -DisplayName $tempRuleName -Group 'k2s' -Direction Inbound -Action Allow -Program "$tempKubeadmDirectory\kubeadm.exe" -Enabled True | Out-Null
        #Below rule is not necessary but adding in case we perform subsequent operations.
        New-NetFirewallRule -DisplayName 'Allow Kubeadm' -Group 'k2s' -Direction Inbound -Action Allow -Program "$kubeToolsPath\kubeadm.exe" -Enabled True | Out-Null

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
        $windowsNodeIpAddress = Get-ConfiguredClusterCIDRNextHop -PodSubnetworkNumber $PodSubnetworkNumber

        Write-Log 'Create config file for join command'
        $joinConfigurationTemplateFilePath = "$kubePath\cfg\kubeadm\joinnode.template.yaml"

        $content = (Get-Content -path $joinConfigurationTemplateFilePath -Raw)
        $content.Replace('__CA_CERT__', $caCertFilePath).Replace('__API__', $apiServerEndpoint).Replace('__TOKEN__', $token).Replace('__SHA__', $hash).Replace('__CRI_SOCKET__', 'npipe:////./pipe/containerd-containerd').Replace('__NODE_IP__', $windowsNodeIpAddress) | Set-Content -Path "$joinConfigurationFilePath"

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
        $rule = Get-NetFirewallRule -DisplayName $tempRuleName -ErrorAction SilentlyContinue
        if ($rule) { Remove-NetFirewallRule -DisplayName $tempRuleName -ErrorAction SilentlyContinue }

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
    Write-Log "kubelet config under: $kubeletConfig"
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

    # Patch node PodCIDR to match expected value for Flannel
    Set-WindowsNodePodCIDR -NodeName $env:computername.ToLower() -PodSubnetworkNumber $PodSubnetworkNumber
}

function Join-LinuxNode {
    Param(
        [string] $NodeName = $(throw 'Argument missing: NodeName'),
        [string] $NodeUserName = $(throw 'Argument missing: NodeUserName'),
        [string] $NodeIpAddress = $(throw 'Argument missing: NodeIpAddress'),
        [scriptblock] $PreStepHook = {}
    )

    # join node if necessary
    $nodefound = &"$kubeToolsPath\kubectl.exe" get nodes | Select-String -Pattern $NodeName -SimpleMatch
    if ( !($nodefound) ) {
        Write-Log "Host $NodeName not yet available as worker node."

        (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo rm -f /etc/kubernetes/kubelet.conf' -UserName $NodeUserName -IpAddress $NodeIpAddress).Output | Write-Log
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo rm -f /etc/kubernetes/pki/ca.crt' -UserName $NodeUserName -IpAddress $NodeIpAddress).Output | Write-Log
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'echo y | sudo kubeadm reset' -UserName $NodeUserName -IpAddress $NodeIpAddress).Output | Write-Log

        &$PreStepHook

        $CommandForJoining = New-JoinCommand

        Write-Log 'Build join command ..'

        $cmdjoin = $CommandForJoining | Select-String -Pattern 'kubeadm join' -CaseSensitive -SimpleMatch
        $cmdjoin.Line = $cmdjoin.Line.replace("`n", '').replace("`r", '')

        $searchPattern = 'kubeadm join (?<api>[^\s]*) --token (?<token>[^\s]*) --discovery-token-ca-cert-hash (?<hash>[^\s]*)'
        $patternSearchResult = $cmdjoin.Line | Select-String -Pattern $searchPattern

        if (($null -eq $patternSearchResult.Matches) -or ($patternSearchResult.Matches.Count -ne 1) -or ($patternSearchResult.Matches.Groups.Count -ne (3 + 1))) {
            $errorMessage = "Could not find the api server endpoint and/or the token and/or the hash from the return value of the command 'sudo kubeadm token create --print-join-command'`n" +
            "  - Command return value: '$($cmdjoin.Line)'`n" +
            "  - Search pattern: '$searchPattern'`n"
            throw $errorMessage
        }

        $apiServerEndpoint = $patternSearchResult.Matches.Groups[1].Value
        $token = $patternSearchResult.Matches.Groups[2].Value
        $hash = $patternSearchResult.Matches.Groups[3].Value
        $caCertFilePath = '/etc/kubernetes/pki/ca.crt'

        Write-Log 'Create config file for join command'
        $joinConfigurationTemplateFilePath = "$kubePath\cfg\kubeadm\joinnode.template.yaml"
        $content = (Get-Content -path $joinConfigurationTemplateFilePath -Raw)
        $content.Replace('__CA_CERT__', $caCertFilePath).Replace('__API__', $apiServerEndpoint).Replace('__TOKEN__', $token).Replace('__SHA__', $hash).Replace('__CRI_SOCKET__', 'unix:///run/crio/crio.sock').Replace('__NODE_IP__', $NodeIpAddress) | Set-Content -Path "$joinConfigurationFilePath"

        Write-Log "Copy config file for join command to node '$NodeIpAddress'"
        $source = $joinConfigurationFilePath
        $target = '/tmp/joinnode.yaml'
        Copy-ToRemoteComputerViaSshKey -Source $source -Target $target -UserName $NodeUserName -IpAddress $NodeIpAddress
   
        $joinCommand = "sudo kubeadm join $apiServerEndpoint" + ' --node-name ' + $NodeName + ' --ignore-preflight-errors IsPrivilegedUser' + " --config `"$target`""
        Write-Log "Created join command: $joinCommand"

        (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo systemctl start crio' -UserName $NodeUserName -IpAddress $NodeIpAddress).Output | Write-Log
        
        $job = Invoke-Expression "Start-Job -ScriptBlock `${Function:Wait-ForNodesReady} -ArgumentList $NodeName"
        Write-Log "Invoke join command in node '$NodeName'"
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute $joinCommand -UserName $NodeUserName -IpAddress $NodeIpAddress).Output | Write-Log

        # print the output of the WaitForJoin.ps1
        Receive-Job $job
        $job | Stop-Job


        # check success in joining
        Write-Log "Check join status for node '$NodeName'"
        $nodefound = &"$kubeToolsPath\kubectl.exe" get nodes | Select-String -Pattern $NodeName -SimpleMatch
        if ( !($nodefound) ) {
            &"$kubeToolsPath\kubectl.exe" get nodes
            throw "Joining the linux node '$NodeName' failed"
        }

        Write-Log "Joining linux node '$NodeName' to cluster is done."
    }
    else {
        Write-Log "Host $NodeName already available as node !"
    }

    # mark node as worker
    Write-Log "Labeling linux node '$NodeName' as worker node"
    &"$kubeToolsPath\kubectl.exe" label nodes $Nodename.ToLower() kubernetes.io/role=worker --overwrite | Out-Null
}

function Remove-LinuxNode {
    Param(
        [string] $NodeName = $(throw 'Argument missing: NodeName'),
        [string] $NodeUserName = $(throw 'Argument missing: NodeUserName'),
        [string] $NodeIpAddress = $(throw 'Argument missing: NodeIpAddress'),
        [scriptblock] $PostStepHook = {}
    )

    (Invoke-Kubectl -Params @('drain', "$NodeName", '--ignore-daemonsets', '--delete-emptydir-data')).Output | ForEach-Object { "$_" } | Write-Log
    (Invoke-Kubectl -Params @('delete', 'node', "$NodeName")).Output | ForEach-Object { "$_" } | Write-Log
    $controlPlaneCIDR = Get-ConfiguredControlPlaneCIDR
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo ip route delete $controlPlaneCIDR" -UserName $NodeUserName -IpAddress $NodeIpAddress).Output | Write-Log
    
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo systemctl stop kubelet' -UserName $NodeUserName -IpAddress $NodeIpAddress).Output | Write-Log
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo rm -rf /etc/kubernetes' -UserName $NodeUserName -IpAddress $NodeIpAddress).Output | Write-Log
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'echo y | sudo kubeadm reset' -UserName $NodeUserName -IpAddress $NodeIpAddress).Output | Write-Log

    (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo rm -rf /etc/cni' -UserName $NodeUserName -IpAddress $NodeIpAddress).Output | Write-Log

    &$PostStepHook

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
        [string] $PodSubnetworkNumber = $(throw 'Argument missing: PodSubnetworkNumber'),
        [string] $JoinCommand = $(throw 'Argument missing: JoinCommand')
    )
    Invoke-Hook -HookName 'AfterVmInitialized' -AdditionalHooksDir $AdditionalHooksDir

    # try to join host windows node
    Write-Log 'starting the join process'
    
    Join-WindowsNode -CommandForJoining $JoinCommand -PodSubnetworkNumber $PodSubnetworkNumber

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

function New-JoinCommand {
    $tokenCreationCommand = 'sudo kubeadm token create --print-join-command'
    $joinCommand = (Invoke-CmdOnControlPlaneViaSSHKey -Retries 3 -CmdToExecute "$tokenCreationCommand").Output 2>&1
    return $joinCommand
}

Export-ModuleMember Initialize-KubernetesCluster,
Uninstall-Cluster, Set-KubeletDiskPressure,
Join-WindowsNode, Join-LinuxNode, Add-K8sContext,
New-JoinCommand, Remove-LinuxNode
