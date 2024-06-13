# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$configModule = "$PSScriptRoot\..\..\..\k2s.infra.module\config\config.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\k2s.infra.module\log\log.module.psm1"
$downloaderModule = "$PSScriptRoot\..\downloader\downloader.module.psm1"
$networkModule = "$PSScriptRoot\..\network\network.module.psm1"
Import-Module $logModule, $configModule, $pathModule, $downloaderModule, $networkModule

$kubePath = Get-KubePath
$kubeBinPath = Get-KubeBinPath


function Initialize-Networking {
    Param(
        [parameter(Mandatory = $true, HelpMessage = 'Host machine is a VM: true, Host machine is not a VM')]
        [bool] $HostVM,
        [parameter(Mandatory = $true, HelpMessage = 'Host-GW or VXLAN, Host-GW: true, false for vxlan')]
        [bool] $HostGW
    )

    # copy flannel files
    Write-Log 'Copy flannel files to right directory'
    mkdir -force "$(Get-SystemDriveLetter):\etc\cni" | Out-Null
    mkdir -force "$(Get-SystemDriveLetter):\etc\cni\net.d" | Out-Null
    mkdir -force "$(Get-SystemDriveLetter):\etc\kube-flannel" | Out-Null
    mkdir -force "$(Get-SystemDriveLetter):\opt" | Out-Null
    mkdir -force "$(Get-SystemDriveLetter):\opt\cni" | Out-Null
    mkdir -force "$(Get-SystemDriveLetter):\opt\cni\bin" | Out-Null
    mkdir -force "$(Get-SystemDriveLetter):\run" | Out-Null
    mkdir -force "$(Get-SystemDriveLetter):\run\flannel" | Out-Null
    mkdir -force "$(Get-SystemDriveLetter):\var\log\flanneld" | Out-Null
    mkdir -force "$(Get-SystemDriveLetter):\var\lib" | Out-Null

    $r = Get-NetFirewallRule -DisplayName 'kubelet' 2> $null;
    if ( $r ) {
        Remove-NetFirewallRule -DisplayName 'kubelet'
    }

    if (!($HostVM)) {
        $kubeVMFirewallRuleName = 'KubeMaster VM'
        $r = Get-NetFirewallRule -DisplayName $kubeVMFirewallRuleName -ErrorAction SilentlyContinue
        if ( $r ) {
            Remove-NetFirewallRule -DisplayName $kubeVMFirewallRuleName -ErrorAction SilentlyContinue
        }
        $ipControlPlane = Get-ConfiguredIPControlPlane
        New-NetFirewallRule -DisplayName $kubeVMFirewallRuleName -Group 'k2s' -Description 'Allow inbound traffic from the Linux VM on ports above 8000' -RemoteAddress $ipControlPlane -RemotePort '8000-32000' -Enabled True -Direction Inbound -Protocol TCP -Action Allow | Out-Null
    }

    $adapterName = Get-L2BridgeName
    Write-Log "Using network adapter '$adapterName'"
    $ipaddresses = @(Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias $adapterName)
    if (!$ipaddresses) {
        throw 'No IP address found which can be used for setting up K2s Setup !'
    }
    $ipaddress = $ipaddresses[0] | Select-Object -ExpandProperty IPAddress
    Write-Log "Using local IP $ipaddress for setup of CNI"

    $clusterCIDRHost = Get-ConfiguredClusterCIDRHost
    $NetworkAddress = "  ""Network"": ""$clusterCIDRHost"","


    $targetFilePath = "$(Get-SystemDriveLetter):\etc\kube-flannel\net-conf.json"
    if ( $HostGW) {
        Write-Log "Writing $targetFilePath for HostGW mode"
        Copy-Item -force "$kubePath\cfg\cni\net-conf.json.template" $targetFilePath

        $lineNetworkAddress = Get-Content $targetFilePath | Select-String NETWORK.ADDRESS | Select-Object -ExpandProperty Line
        if ( $lineNetworkAddress ) {
            $content = Get-Content $targetFilePath
            $content | ForEach-Object { $_ -replace $lineNetworkAddress, $NetworkAddress } | Set-Content $targetFilePath
        }
    }
    else {
        Write-Log "Writing $targetFilePath for VXLAN mode"
        Copy-Item -force "$kubePath\cfg\cni\net-conf-vxlan.json.template" $targetFilePath

        $lineNetworkAddress = Get-Content $targetFilePath | Select-String NETWORK.ADDRESS | Select-Object -ExpandProperty Line
        if ( $lineNetworkAddress ) {
            $content = Get-Content $targetFilePath
            $content | ForEach-Object { $_ -replace $lineNetworkAddress, $NetworkAddress } | Set-Content $targetFilePath
        }
    }

    if (!($HostVM)) {
        # save the current IP address to make a later check possible
        Set-ConfigHostGW -Value $HostGW
    }

    Copy-Item -Path "$kubeBinPath\cni\*" -Destination "$(Get-SystemDriveLetter):\opt\cni\bin" -Recurse
}

function Reset-WinServices {
    &"$kubeBinPath\nssm" set kubeproxy Start SERVICE_DEMAND_START | Out-Null
    &"$kubeBinPath\nssm" set kubelet Start SERVICE_DEMAND_START | Out-Null
    &"$kubeBinPath\nssm" set flanneld Start SERVICE_DEMAND_START | Out-Null
}

function Initialize-WinNode {
    Param(
        [parameter(Mandatory = $true, HelpMessage = 'Kubernetes version to use')]
        [string] $KubernetesVersion,
        [parameter(Mandatory = $false, HelpMessage = 'Host machine is a VM: true, Host machine is not a VM')]
        [bool] $HostVM = $false,
        [parameter(Mandatory = $true, HelpMessage = 'Host-GW or VXLAN, Host-GW: true, false for vxlan')]
        [bool] $HostGW,
        [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
        [boolean] $DeleteFilesForOfflineInstallation = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Force the installation online. This option is needed if the files for an offline installation are available but you want to recreate them.')]
        [boolean] $ForceOnlineInstallation = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Skips networking setup and installation of cluster dependent tools kubelet, flannel on windows node')]
        [boolean] $SkipClusterSetup = $false
    )

    Invoke-DeployWinArtifacts -KubernetesVersion $KubernetesVersion -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation -ForceOnlineInstallation $ForceOnlineInstallation -SkipClusterSetup:$SkipClusterSetup

    Set-ConfigInstallFolder -Value $kubePath
    Set-ConfigProductVersion -Value $productVersion

    if (!(Test-Path "$kubeBinPath\exe")) {
        New-Item -ItemType 'directory' -Path "$kubeBinPath\exe" | Out-Null
    }

    if (! $SkipClusterSetup ) {
        if (!$KubernetesVersion.StartsWith('v')) {
            $KubernetesVersion = 'v' + $KubernetesVersion
        }
        Write-Log "Using Kubernetes version: $KubernetesVersion"

        if ($HostVM) {
            [Environment]::SetEnvironmentVariable('KUBECONFIG', "$kubePath\config", [System.EnvironmentVariableTarget]::Machine)
        }

        $previousKubernetesVersion = Get-ConfigInstalledKubernetesVersion
        Write-Log("Previous K8s version: $previousKubernetesVersion, current K8s version to install: $KubernetesVersion")

        $productVersion = Get-ProductVersion

        Set-ConfigInstalledKubernetesVersion -Value $KubernetesVersion

        Initialize-Networking -HostVM:$HostVM -HostGW:$HostGW
    }
    else {
        Write-Log 'Skipping networking setup on windows node'
    }

    Install-WinNodeArtifacts -HostVM:$HostVM -SkipClusterSetup:$SkipClusterSetup

    if (! $SkipClusterSetup) {
        Reset-WinServices
    }
}

function Uninstall-WinNode {
    param(
        $ShallowUninstallation = $false
    )
    Write-Log 'Uninstalling Windows worker node' -Console
    Remove-DefaultNetNat

    Remove-ServiceIfExists 'flanneld'
    Remove-ServiceIfExists 'kubelet'
    Remove-ServiceIfExists 'kubeproxy'
    Remove-ServiceIfExists 'windows_exporter'
    Remove-ServiceIfExists 'httpproxy'
    Remove-ServiceIfExists 'dnsproxy'

    # remove firewall rules
    Remove-NetFirewallRule -Group 'k2s' -ErrorAction SilentlyContinue

    Write-Log 'Uninstall containerd service if existent'
    Uninstall-WinContainerd -ShallowUninstallation $ShallowUninstallation
    Uninstall-WinDocker -ShallowUninstallation $ShallowUninstallation
}


function Clear-WinNode {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
        [Boolean] $DeleteFilesForOfflineInstallation = $false,
        [Boolean] $ShallowDeletion = $false
    )
    $kubeletConfigDir = Get-KubeletConfigDir
    # remove folders from installation folder
    Get-ChildItem -Path $kubeletConfigDir -Force -Recurse -Attributes Reparsepoint -ErrorAction 'silentlycontinue' | % { $n = $_.FullName.Trim('\'); fsutil reparsepoint delete "$n" }
    Remove-Item -Path "$(Get-SystemDriveLetter):\etc" -Force -Recurse -ErrorAction SilentlyContinue
    Remove-Item -Path "$(Get-SystemDriveLetter):\run" -Force -Recurse -ErrorAction SilentlyContinue
    Remove-Item -Path "$(Get-SystemDriveLetter):\opt" -Force -Recurse -ErrorAction SilentlyContinue
    Remove-Item -Path "$(Get-InstallationDriveLetter):\run" -Force -Recurse -ErrorAction SilentlyContinue

    if (!$ShallowDeletion) {
        $setupFilePath = Get-SetupConfigFilePath
        Remove-Item -Path "$setupFilePath" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$kubeBinPath\kube*.exe" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$kubeBinPath\nerdctl.exe" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$kubeBinPath\jq.exe" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$kubeBinPath\yq.exe" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$kubeBinPath\dnsproxy.exe" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$kubeBinPath\dnsproxy.yaml" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$kubeBinPath\cri*.exe" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$kubeBinPath\crictl.yaml" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$kubeBinPath\exe" -Force -Recurse -ErrorAction SilentlyContinue
        Remove-Item -Path "$kubePath\config" -Force -ErrorAction SilentlyContinue
        #Backward compatibility for few versions
        Remove-Item -Path "$kubePath\cni\bin\win*.exe" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$kubePath\cni\bin\flannel.exe" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$kubePath\cni\bin\host-local.exe" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$kubePath\cni\bin\vfprules.json" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$kubePath\cni\bin" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$kubePath\cni\conf" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$kubePath\cni" -Force -ErrorAction SilentlyContinue

        Remove-Item -Path "$kubePath\bin\cni\win*.exe" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$kubePath\bin\cni\flannel.exe" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$kubePath\bin\cni\host-local.exe" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$kubePath\bin\cni\vfprules.json" -Force -ErrorAction SilentlyContinue

        Remove-Item -Path "$kubePath\kubevirt\bin\*.exe" -Force -ErrorAction SilentlyContinue

        Remove-Item -Path "$kubePath\smallsetup\en_windows*business*.iso" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$kubePath\debian*.qcow2" -Force -ErrorAction SilentlyContinue

        Remove-Item -Path "$kubeBinPath\plink.exe" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$kubeBinPath\pscp.exe" -Force -ErrorAction SilentlyContinue

        Remove-Nssm
    }
    Invoke-DownloadsCleanup -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation
}

Export-ModuleMember Initialize-WinNode, Uninstall-WinNode, Clear-WinNode, Initialize-Networking, Reset-WinServices