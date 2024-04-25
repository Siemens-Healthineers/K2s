# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Join the windows node with the remote linux master

.DESCRIPTION
This script assists with joining a Windows node to a cluster.

.EXAMPLE
PS> .\JoinWindowsHost.ps1
#>

Param(
    [Parameter(HelpMessage = 'When executing ssh.exe in nested environment[host=>VM=>VM], -n flag should not be used.')]
    [switch]$Nested = $false
)

# load global settings
&$PSScriptRoot\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\GlobalFunctions.ps1

Import-Module "$PSScriptRoot/../ps-modules/log/log.module.psm1"

# join node if necessary
$nodefound = &$global:KubectlExe get nodes | Select-String -Pattern $env:COMPUTERNAME -SimpleMatch
if ( !($nodefound) ) {

    # copy kubeadmin to c:
    $tempKubeadmDirectory = $global:SystemDriveLetter + ":\k"
    $bPathAvailable = Test-Path -Path $tempKubeadmDirectory
    if( !$bPathAvailable ) { mkdir -Force $tempKubeadmDirectory  | Out-Null }
    Copy-Item -Path "$global:KubernetesPath\bin\exe\kubeadm.exe" -Destination $tempKubeadmDirectory -Force

    Write-Log "Add kubeadm to firewall rules"
    New-NetFirewallRule -DisplayName 'Allow temp Kubeadm' -Group 'k2s' -Direction Inbound -Action Allow -Program "$tempKubeadmDirectory\kubeadm.exe" -Enabled True | Out-Null
    #Below rule is not neccessary but adding in case we perform subsequent operations.
    New-NetFirewallRule -DisplayName "Allow Kubeadm" -Group "k2s" -Direction Inbound -Action Allow -Program "$global:KubernetesPath\bin\exe\kubeadm.exe" -Enabled True | Out-Null

    Write-Log "Host $env:COMPUTERNAME not yet available as worker node."

    & "$tempKubeadmDirectory\kubeadm.exe" reset -f 3>&1 2>&1 | Write-Log
    Get-ChildItem -Path $global:KubeletConfigDir -Force -Recurse -Attributes Reparsepoint -ErrorAction 'silentlycontinue' | % { $n = $_.FullName.Trim('\'); fsutil reparsepoint delete "$n" }
    Remove-Item -Path "$global:KubeletConfigDir\etc" -Force -Recurse -ErrorAction SilentlyContinue
    New-Item -Path "$global:KubeletConfigDir\etc" -ItemType SymbolicLink -Value "$($global:SystemDriveLetter):\etc" | Out-Null
    # get join command
    # Remove-Job -Name JoinK8sJob -Force -ErrorAction SilentlyContinue
    Write-Log "Build join command .."

    $tokenCreationCommand = "sudo kubeadm token create --print-join-command"
    $cmdjoin = ExecCmdMaster "$tokenCreationCommand" -Nested:$Nested -NoLog 2>&1 | Select-String -Pattern 'kubeadm join' -CaseSensitive -SimpleMatch
    $cmdjoin.Line = $cmdjoin.Line.replace("`n", '').replace("`r", '')

    $searchPattern = 'kubeadm join (?<api>[^\s]*) --token (?<token>[^\s]*) --discovery-token-ca-cert-hash (?<hash>[^\s]*)'
    $patternSearchResult = $cmdjoin.Line | Select-String -Pattern $searchPattern

    if (($null -eq $patternSearchResult.Matches) -or ($patternSearchResult.Matches.Count -ne 1) -or ($patternSearchResult.Matches.Groups.Count -ne (3+1))) {
        $errorMessage = "Could not find the api server endpoint and/or the token and/or the hash from the return value of the command '$tokenCreationCommand'`n" +
        "  - Command return value: '$($cmdjoin.Line)'`n" +
        "  - Search pattern: '$searchPattern'`n"
        throw $errorMessage
    }

    $apiServerEndpoint = $patternSearchResult.Matches.Groups[1].Value
    $token = $patternSearchResult.Matches.Groups[2].Value
    $hash = $patternSearchResult.Matches.Groups[3].Value
    $caCertFilePath = "$($global:SystemDriveLetter):\etc\kubernetes\pki\ca.crt"
    $windowsNodeIpAddress = $global:ClusterCIDR_NextHop

    Write-Log "Create config file for join command"
    $joinConfigurationTemplateFilePath = "$PSScriptRoot\JoinWindowsHost.template.yaml"
    $content = (Get-Content -path $joinConfigurationTemplateFilePath -Raw)
    $content.Replace('__CA_CERT__', $caCertFilePath).Replace('__API__', $apiServerEndpoint).Replace('__TOKEN__', $token).Replace('__SHA__', $hash).Replace('__NODE_IP__', $windowsNodeIpAddress) | Set-Content -Path "$global:JoinConfigurationFilePath"

    $joinCommand = '.\' + "kubeadm join $apiServerEndpoint" + ' --node-name ' + $env:COMPUTERNAME + ' --ignore-preflight-errors IsPrivilegedUser' + " --config `"$global:JoinConfigurationFilePath`""

    Write-Log $joinCommand

    $job = Invoke-Expression "Start-Job -ScriptBlock { &`"$global:KubernetesPath\smallsetup\common\WaitForJoin.ps1`" }"
    cd $tempKubeadmDirectory
    Invoke-Expression $joinCommand 2>&1 | Write-Log
    cd ..\..

    # print the output of the WaitForJoin.ps1
    Receive-Job $job
    $job | Stop-Job

    # delete temporary kubeadm path if it was created
    Remove-Item -Path $tempKubeadmDirectory\kubeadm.exe
    if( !$bPathAvailable ) { Remove-Item -Path $tempKubeadmDirectory }

    # check success in joining
    $nodefound = &$global:KubectlExe get nodes | Select-String -Pattern $env:COMPUTERNAME -SimpleMatch
    if ( !($nodefound) ) {
        &$global:KubectlExe get nodes
        throw 'Joining the windows node failed'
    }

    Write-Log "Joining node $env:COMPUTERNAME to cluster is done."
}
else {
    Write-Log "Host $env:COMPUTERNAME already available as node !"
}

# check success in creating kubelet config file
$kubeletConfig = "$global:KubeletConfigDir\config.yaml"
Write-Log "Using kubelet file: $kubeletConfig"
if (! (Test-Path $kubeletConfig)) {
    throw "Expected file not created: $kubeletConfig"
}
if (! (Get-Content $kubeletConfig | Select-String -Pattern 'KubeletConfiguration' -SimpleMatch)) {
    throw "Wrong content in $kubeletConfig, aborting"
}
$kubeletEnv = "$global:KubeletConfigDir\kubeadm-flags.env"
if (! (Test-Path $kubeletEnv)) {
    throw "Expected file not created: $kubeletEnv"
}

# mark nodes as worker
Write-Log "Labeling windows node as worker node"
&$global:KubectlExe label nodes $env:computername.ToLower() kubernetes.io/role=worker --overwrite | Out-Null

