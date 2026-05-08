# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$infraModule =   "$PSScriptRoot\..\..\..\k2s.infra.module\k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\k2s.cluster.module\k2s.cluster.module.psm1"

Import-Module $infraModule, $clusterModule

function Repair-LinuxWorkerNodeRegistriesConfig {
    Param(
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress')
    )

    $duplicateCountOutput = (Invoke-CmdOnVmViaSSHKey -CmdToExecute "if [ -f /etc/containers/registries.conf ]; then grep -c '^[[:space:]]*unqualified-search-registries[[:space:]]*=' /etc/containers/registries.conf 2>/dev/null || echo 0; else echo 0; fi" -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output.Trim()
    $duplicateCount = 0
    [void][int]::TryParse($duplicateCountOutput, [ref]$duplicateCount)

    if ($duplicateCount -le 1) {
        Write-Log "[RegistryConfig] registries.conf on node $IpAddress has $duplicateCount unqualified-search-registries entries, no repair needed."
        return
    }

    # Remove all unqualified-search-registries lines and add a single one at the top
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo sh -c 'grep -v \"^[[:space:]]*unqualified-search-registries[[:space:]]*=\" /etc/containers/registries.conf > /tmp/registries.conf.k2s; echo \"unqualified-search-registries = [\\\"docker.io\\\", \\\"quay.io\\\"]\" | cat - /tmp/registries.conf.k2s > /tmp/registries.conf.final; mv /tmp/registries.conf.final /etc/containers/registries.conf; rm -f /tmp/registries.conf.k2s'" -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output | Write-Log
    Write-Log "[RegistryConfig] Restarting crio after registries.conf normalization on node $IpAddress."
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo systemctl restart crio' -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output | Write-Log
}

function Clear-LinuxWorkerNodeRoutes {
    <#
    .SYNOPSIS
        Cleans only Kubernetes-related routes on a Linux worker node.
    .DESCRIPTION
        Removes control plane CIDR route, pod-network routes (e.g. /24 and /16),
        and cni0 interface if present. Safe to call multiple times.
    #>
    Param(
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress')
    )

    Write-Log "[RouteCleanup] Cleaning Kubernetes-related routes on node $IpAddress" -Console

    # Control plane route (e.g. 172.19.1.0/24)
    # Keep kernel-connected route (proto kernel scope link), delete only manually-added route.
    $controlPlaneCIDR = Get-ConfiguredControlPlaneCIDR
    $controlPlaneRoute = (Invoke-CmdOnVmViaSSHKey -CmdToExecute "ip route show $controlPlaneCIDR | head -1" -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output.Trim()
    if (-not [string]::IsNullOrWhiteSpace($controlPlaneRoute)) {
        if ($controlPlaneRoute -match 'proto kernel|scope link') {
            Write-Log "[RouteCleanup] Keeping connected route: $controlPlaneRoute"
        } else {
            Write-Log "[RouteCleanup] Deleting route: $controlPlaneCIDR"
            (Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo ip route delete $controlPlaneCIDR" -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output | Write-Log
        }
    } else {
        Write-Log "[RouteCleanup] Route $controlPlaneCIDR not found, skipping."
    }

    # Pod routes (e.g. 172.20.0.0/24 via 172.19.1.100 and 172.20.0.0/16 via 172.19.1.1)
    $podNetworkCIDR = Get-ConfiguredClusterCIDR
    $podNetworkPrefix = (($podNetworkCIDR -split '/')[0] -split '\.')[0..1] -join '\.'
    $podRoutes = (Invoke-CmdOnVmViaSSHKey -CmdToExecute "ip route | grep -E '^$podNetworkPrefix\.'" -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output
    if (-not [string]::IsNullOrWhiteSpace($podRoutes)) {
        $podRoutes -split "`n" | ForEach-Object {
            $routeLine = $_.Trim()
            $route = ($routeLine -split '\s')[0]
            if (-not [string]::IsNullOrWhiteSpace($route)) {
                if ($routeLine -match 'proto kernel|scope link') {
                    Write-Log "[RouteCleanup] Keeping connected route: $routeLine"
                } else {
                    Write-Log "[RouteCleanup] Deleting route: $route"
                    (Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo ip route delete $route" -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output | Write-Log
                }
            }
        }
    } else {
        Write-Log "[RouteCleanup] No pod routes matching $podNetworkPrefix.* found, skipping."
    }

    # cni0 interface (created by flannel)
    $cni0Exists = -not [string]::IsNullOrWhiteSpace((Invoke-CmdOnVmViaSSHKey -CmdToExecute "ip link show cni0 2>/dev/null" -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output)
    if ($cni0Exists) {
        Write-Log "[RouteCleanup] Deleting interface: cni0"
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo ip link delete cni0" -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output | Write-Log
    } else {
        Write-Log "[RouteCleanup] cni0 not found, skipping."
    }

    Write-Log "[RouteCleanup] Kubernetes route cleanup completed" -Console
}

function Add-LinuxWorkerNode {
    Param(
        [string] $NodeName = $(throw 'Argument missing: NodeName'),
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $WindowsHostIpAddress = $(throw 'Argument missing: WindowsHostIpAddress'),
        [string] $Proxy = '',
        [string] $AdditionalHooksDir = '',
        [string] $installedDistributionOnRemoteComputer = $(throw 'Argument missing: installedDistributionOnRemoteComputer'),
        [string] $NodePackagePath = '',
        [ValidateSet('HOST', 'VM-EXISTING')]
        [string] $NodeType = 'HOST'
    )

    $nodeParams = @{
        Name = $NodeName
        IpAddress = $IpAddress
        UserName = $UserName
        Proxy = $Proxy
        NodeType = $NodeType
        Role = 'worker'
        OS = 'linux'
        PodCIDR = '' # will be filled during start of node
    }
    Add-NodeConfig @nodeParams

    Write-Log "Installing node essentials" -Console

    Write-Log "Prepare the computer $IpAddress for provisioning"

    Set-UpComputerBeforeProvisioning -UserName $UserName -IpAddress $IpAddress -Proxy $Proxy -InstalledDistribution $installedDistributionOnRemoteComputer

    Install-LinuxPackagesAndAddContainerImagesIntoRemoteComputer -UserName $UserName -IpAddress $IpAddress -Proxy $Proxy -InstalledDistribution $installedDistributionOnRemoteComputer -NodePackagePath $NodePackagePath

    Repair-LinuxWorkerNodeRegistriesConfig -UserName $UserName -IpAddress $IpAddress

    # Cleanup Kubernetes-related routes before add/join flow
    Clear-LinuxWorkerNodeRoutes -UserName $UserName -IpAddress $IpAddress

    $doBeforeJoining = {
        Write-Log "Configuring networking for adding the node" -Console
        # add a route to the cluster network over the Windows host IP address
        $controlPlaneCIDR = Get-ConfiguredControlPlaneCIDR
        $controlPlaneRouteExists = -not [string]::IsNullOrWhiteSpace((Invoke-CmdOnVmViaSSHKey -CmdToExecute "ip route show $controlPlaneCIDR" -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output)
        if ($controlPlaneRouteExists) {
            Write-Log "[Route] Route $controlPlaneCIDR already exists, skipping add."
        } else {
            (Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo ip route add $controlPlaneCIDR via $WindowsHostIpAddress" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
        }

        $podNetworkCIDR = Get-ConfiguredClusterCIDR
        $podNetworkRouteExists = -not [string]::IsNullOrWhiteSpace((Invoke-CmdOnVmViaSSHKey -CmdToExecute "ip route show $podNetworkCIDR" -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output)
        if ($podNetworkRouteExists) {
            Write-Log "[Route] Route $podNetworkCIDR already exists, skipping add."
        } else {
            (Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo ip route add $podNetworkCIDR via $WindowsHostIpAddress" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
        }

        $networkInterfaceName = (Get-NetIPAddress | Where-Object { $_.AddressFamily -eq "IPv4" -and ($_.IPAddress -match $WindowsHostIpAddress)} | Select-Object -ExpandProperty InterfaceAlias)
        if ([string]::IsNullOrWhiteSpace($networkInterfaceName)) {
            throw "Cannot find the network interface belonging to the IP address '$WindowsHostIpAddress'"
        }

        netsh int ipv4 set int $networkInterfaceName forwarding=enabled | Out-Null
    }

    Write-Log "Joining new node to the cluster" -Console
    $k8sFormattedNodeName = $NodeName.ToLower()
    Join-LinuxNode -NodeName $k8sFormattedNodeName.ToLower() -NodeUserName $UserName -NodeIpAddress $IpAddress -PreStepHook $doBeforeJoining
}

function Remove-LinuxWorkerNode {
    Param(
        [string] $NodeName = $(throw 'Argument missing: NodeName'),
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $AdditionalHooksDir = ''
    )
    Write-Log "Removing K2s worker node '$NodeName'"

    $doAfterRemoving = {
        Clear-LinuxWorkerNodeRoutes -UserName $UserName -IpAddress $IpAddress
    }

    $k8sFormattedNodeName = $NodeName.ToLower()
    $clusterState = (Invoke-Kubectl -Params @('get', 'nodes', '-o', 'wide')).Output
    if ($clusterState -match $k8sFormattedNodeName) {
        Remove-LinuxNode -NodeName $k8sFormattedNodeName -NodeUserName $UserName -NodeIpAddress $IpAddress -PostStepHook $doAfterRemoving
        Write-Log "Removed node from the cluster" -Console
    }

    Remove-KubernetesArtifacts -UserName $UserName -IpAddress $IpAddress
    Write-Log "Removed node essentials from the remote machine" -Console

    Remove-NodeConfig -Name $NodeName

    Write-Log "Removing K2s worker node '$NodeName' complete."
}

function Start-LinuxWorkerNode {
    Param(
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $NodeName = $(throw 'Argument missing: NodeName'),
        [string] $AdditionalHooksDir = '',
        [switch] $ObtainCIDR = $false
    )

    $clusterCIDRWorker = Get-ClusterCIDRWorker -NodeName $NodeName -ObtainCIDR:$ObtainCIDR
    Add-RouteToLinuxWorkerNode -NodeName $NodeName -IpAddress $IpAddress -ClusterCIDRWorker $clusterCIDRWorker
    Add-WorkerVFPRoute -NodeName $NodeName -ClusterCIDRWorker $clusterCIDRWorker

    Write-Log "K2s worker node '$NodeName' started" -Console
}

function Add-WorkerVFPRoute {
    Param(
        [string] $NodeName = $(throw 'Argument missing: Hostname'),
        [string] $ClusterCIDRWorker = $(throw 'Argument missing: Hostname')
    )

    $setupConfigRoot = Get-RootConfigk2s
    $defaultGateway = $setupConfigRoot.psobject.properties['cbr0'].value
    Add-VfpRoute -Name $NodeName -Subnet $ClusterCIDRWorker -Gateway $defaultGateway
}

function Stop-LinuxWorkerNode {
    Param(
        [string] $NodeName = $(throw 'Argument missing: NodeName'),
        [string] $AdditionalHooksDir = '',
        [switch] $SkipHeaderDisplay = $false

    )

    $clusterCIDRWorker = Get-ClusterCIDRWorker -NodeName $NodeName
    Remove-RouteToLinuxWorkerNode -NodeName $NodeName -ClusterCIDRWorker $clusterCIDRWorker
    Remove-VfpRoute -Name $NodeName

    Write-Log "K2s worker node '$NodeName' stopped" -Console
}

function Get-ClusterCIDRWorker {
    Param (
        [string] $NodeName = $(throw 'Argument missing: Hostname'),
        [switch] $ObtainCIDR = $false
    )

    $setupConfigRoot = Get-RootConfigk2s
    $clusterCIDRWorkerTemplate = $setupConfigRoot.psobject.properties['podNetworkWorkerCIDR_2'].value

    $clusterCIDRWorker = ''
    if (!$ObtainCIDR) {
        Write-Log 'Getting Node CIDR from config'
        $node = Get-NodeConfig -NodeName $NodeName
        if ($null -ne $node) {
            $clusterCIDRWorker = $node.PodCIDR
        }
    }

    if ($clusterCIDRWorker -eq '' -or $ObtainCIDR) {
        $output = Get-AssignedPodSubnetworkNumber -NodeName $NodeName
        if ($output.Success) {
            $assignedPodSubnetworkNumber = $output.PodSubnetworkNumber
            $clusterCIDRWorker = $clusterCIDRWorkerTemplate.Replace('X', $assignedPodSubnetworkNumber)

            Update-NodeConfig -Name $NodeName -Updates @{
                PodCIDR = $clusterCIDRWorker
            }
        } else {
            throw "Cannot obtain pod network information from node '$NodeName'"
        }
    }

    return $clusterCIDRWorker
}

function Add-RouteToLinuxWorkerNode {
    Param(
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $NodeName = $(throw 'Argument missing: Hostname'),
        [string] $ClusterCIDRWorker = $(throw 'Argument missing: ClusterCIDRWorker')
    )

    # routes for Linux pods to external nodes
    Write-Log "Remove obsolete route to $ClusterCIDRWorker"
    route delete $ClusterCIDRWorker >$null 2>&1
    Write-Log "Add route to Pods for node:$NodeName CIDR:$ClusterCIDRWorker"
    route -p add $ClusterCIDRWorker $IpAddress METRIC 4 | Out-Null
}

function Remove-RouteToLinuxWorkerNode {
    Param(
        [string] $NodeName = $(throw 'Argument missing: Hostname'),
        [string] $ClusterCIDRWorker = $(throw 'Argument missing: ClusterCIDRWorker')
    )

    # routes for Linux pods
    Write-Log "Remove obsolete route to $ClusterCIDRWorker"
    route delete $ClusterCIDRWorker >$null 2>&1
}

function Install-LinuxPackagesAndAddContainerImagesIntoRemoteComputer {
    Param(
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $Proxy = '',
        [string] $installedDistributionOnRemoteComputer = $(throw 'Argument missing: InstalledDistribution'),
        [string] $NodePackagePath = ''
    )

    # ---------------------------------------------------------------------------
    # Offline path: node package zip supplied → extract into 'linuxnode' folder
    # ---------------------------------------------------------------------------
    if (![string]::IsNullOrWhiteSpace($NodePackagePath)) {
        if (!(Test-Path $NodePackagePath)) {
            throw "[NodeAdd] Node package not found: '$NodePackagePath'"
        }

        Write-Log "[NodeAdd] --node-package supplied: '$NodePackagePath'. Using offline installation." -Console

        # Extract zip to a temp staging area
        $extractTempPath = Join-Path ([System.IO.Path]::GetTempPath()) "k2s-node-pkg-extract-$([guid]::NewGuid().ToString().Substring(0, 8))"
        New-Item -Path $extractTempPath -ItemType Directory -Force | Out-Null
        Write-Log "[NodeAdd] Extracting node package to staging: '$extractTempPath'" -Console
        Expand-Archive -LiteralPath $NodePackagePath -DestinationPath $extractTempPath -Force
        Write-Log "[NodeAdd] Node package extracted." -Console

        # Validate expected content
        $zipPackagesPath = Join-Path $extractTempPath 'packages'
        $zipPackagesPathWithOs = Join-Path $zipPackagesPath $installedDistributionOnRemoteComputer
        $zipImagesPath   = Join-Path $extractTempPath 'images'
        if (!(Test-Path $zipPackagesPath)) {
            throw "[NodeAdd] Expected 'packages' folder not found in node package: '$zipPackagesPath'"
        }

        $zipPackagesPathToUse = $zipPackagesPath
        if (Test-Path $zipPackagesPathWithOs) {
            $zipPackagesPathToUse = $zipPackagesPathWithOs
        } else {
            Write-Log "[NodeAdd] WARNING: OS-specific packages path '$zipPackagesPathWithOs' not found. Falling back to '$zipPackagesPath'." -Console
        }

        # Prepare the 'linuxnode' artifacts directory: keep folder, overwrite contents
        $linuxNodeDir = Get-DirectoryOfLinuxNodeArtifactsOnWindowsHost
        if (!(Test-Path $linuxNodeDir)) {
            New-Item -Path $linuxNodeDir -ItemType Directory -Force | Out-Null
            Write-Log "[NodeAdd] Created 'linuxnode' directory: '$linuxNodeDir'" -Console
        } else {
            Write-Log "[NodeAdd] Using existing 'linuxnode' directory: '$linuxNodeDir'" -Console
        }

        $linuxNodePackagesPath = Join-Path $linuxNodeDir 'packages'
        $linuxNodePackagesByOsPath = Join-Path $linuxNodePackagesPath $installedDistributionOnRemoteComputer
        $linuxNodeImagesPath = Join-Path $linuxNodeDir 'images'

        if (Test-Path $linuxNodePackagesByOsPath) {
            Write-Log "[NodeAdd] Overwriting existing packages content in '$linuxNodePackagesByOsPath'" -Console
            Remove-Item -Path $linuxNodePackagesByOsPath -Recurse -Force
        }
        if (Test-Path $linuxNodeImagesPath) {
            Write-Log "[NodeAdd] Overwriting existing images content in '$linuxNodeImagesPath'" -Console
            Remove-Item -Path $linuxNodeImagesPath -Recurse -Force
        }

        # Copy packages and images from extracted zip into linuxnode
        New-Item -Path $linuxNodePackagesByOsPath -ItemType Directory -Force | Out-Null
        Write-Log "[NodeAdd] Copying packages from node package into '$linuxNodePackagesByOsPath'" -Console
        Copy-Item -Path "$zipPackagesPathToUse\*" -Destination $linuxNodePackagesByOsPath -Recurse -Force

        if (Test-Path $zipImagesPath) {
            Write-Log "[NodeAdd] Copying images from node package into '$linuxNodeDir\images'" -Console
            Copy-Item -Path $zipImagesPath -Destination $linuxNodeDir -Recurse -Force
        } else {
            Write-Log "[NodeAdd] WARNING: 'images' folder not found in node package. Skipping image copy." -Console
        }

        # Cleanup temp staging
        Remove-Item -Path $extractTempPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    # ---------------------------------------------------------------------------
    # Online path: discover packages from control plane or download from internet
    # ---------------------------------------------------------------------------
    $controlPlaneUserName = Get-DefaultUserNameControlPlane
    $controlPlaneIpAddress = Get-ConfiguredIPControlPlane
    $installedDistributionOnControlPlane = Get-InstalledDistribution -UserName $controlPlaneUserName -IpAddress $controlPlaneIpAddress
    Write-Log "Installed distribution in the control plane: $installedDistributionOnControlPlane"
    Write-Log "Installed distribution in the machine with IP '$IpAddress': $installedDistributionOnRemoteComputer"
   
    $baseDirectoryOfKubenodeDebPackagesOnWindowsHost = Get-BaseDirectoryOfKubenodeDebPackagesOnWindowsHost
    $windowsHostDebPackagesSourcePath = "$baseDirectoryOfKubenodeDebPackagesOnWindowsHost\$installedDistributionOnRemoteComputer"

    $linuxNodeArtifactsPackagePath = Get-PathOfLinuxNodeArtifactsPackageOnWindowsHost
    $linuxNodeArtifactsPath = Get-DirectoryOfLinuxNodeArtifactsOnWindowsHost

    $packagePathExists = $(Test-Path -Path $linuxNodeArtifactsPackagePath)
    $linuxNodeArtifactsPathExists = $(Test-Path -Path $linuxNodeArtifactsPath)

    Write-Log "Zip file '$linuxNodeArtifactsPackagePath' with Linux node artifacts exists?: $packagePathExists"
    Write-Log "Folder '$linuxNodeArtifactsPath' with Linux node artifacts exists?: $linuxNodeArtifactsPathExists"

    if (!($linuxNodeArtifactsPathExists) -and ($packagePathExists) -and [string]::IsNullOrWhiteSpace($NodePackagePath)) {
        Write-Log "Create folder '$linuxNodeArtifactsPath'"
        New-Item -Path $linuxNodeArtifactsPath -ItemType Directory -Force | Out-Null
        Write-Log "Extracting content of file '$linuxNodeArtifactsPackagePath' into '$linuxNodeArtifactsPath'"
        Expand-Archive -LiteralPath $linuxNodeArtifactsPackagePath -DestinationPath $linuxNodeArtifactsPath
    } 

    $distributionDebPackagesSourcePathExists = $(Test-Path -Path $windowsHostDebPackagesSourcePath)
    Write-Log "Folder with deb packages '$windowsHostDebPackagesSourcePath' exists?: $distributionDebPackagesSourcePathExists"
    if ($distributionDebPackagesSourcePathExists) {
        Write-Log "The content of the folder '$windowsHostDebPackagesSourcePath' will be used"
    } 
    
    $kubernetesDebPackagesTargetPath = Get-KubernetesDebPackagesPath -UserName $UserName
    Add-KubernetesArtifactsToRemoteComputer -UserName $UserName -IpAddress $IpAddress -Proxy $Proxy -SourcePath $windowsHostDebPackagesSourcePath -TargetPath $kubernetesDebPackagesTargetPath -InstalledDistribution $installedDistributionOnRemoteComputer
    Install-KubernetesArtifacts -UserName $UserName -IpAddress $IpAddress -Proxy $Proxy -SourcePath $kubernetesDebPackagesTargetPath -InstalledDistribution $installedDistributionOnRemoteComputer

    $buildahDebPackagesTargetPath = Get-BuildahDebPackagesPath -UserName $UserName
    Add-BuildahArtifactsToRemoteComputer -UserName $UserName -IpAddress $IpAddress -SourcePath $windowsHostDebPackagesSourcePath -TargetPath $buildahDebPackagesTargetPath -InstalledDistribution $installedDistributionOnRemoteComputer
    Install-BuildahDebPackages -UserName $UserName -IpAddress $IpAddress -SourcePath $buildahDebPackagesTargetPath -InstalledDistribution $installedDistributionOnRemoteComputer

    Copy-KubernetesImagesFromControlPlaneToRemoteComputer -UserName $UserName -IpAddress $IpAddress
}

function Test-SupportedWorkerOS {
    <#
    .SYNOPSIS
        Validates that the given OS key is listed in supportedWorkerOS in cfg/config.json.
    .PARAMETER OS
        The combined OS+version key to validate (e.g. 'debian12', 'debian13').
    .PARAMETER InstallationPath
        The K2s installation root. Defaults to Get-KubePath when not specified.
    #>
    param(
        [string] $OS = $(throw 'Argument missing: OS'),
        [string] $InstallationPath = ''
    )

    if ($InstallationPath -eq '') {
        $InstallationPath = Get-KubePath
    }

    $configPath = Join-Path $InstallationPath 'cfg\config.json'
    if (!(Test-Path $configPath)) {
        throw "Configuration file not found: $configPath"
    }

    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    $supportedOS = $config.supportedWorkerOS
    if (!$supportedOS) {
        throw 'No supported OS configurations found in cfg/config.json'
    }

    foreach ($supported in $supportedOS) {
        if ($supported.os -eq $OS) {
            Write-Log "[WorkerOS] OS '$OS' is supported" -Console
            return
        }
    }

    $supportedList = ($supportedOS | ForEach-Object { $_.os }) -join ', '
    throw "OS '$OS' is not supported. Supported: $supportedList"
}

Export-ModuleMember -Function Add-LinuxWorkerNode,
Remove-LinuxWorkerNode,
Clear-LinuxWorkerNodeRoutes,
Start-LinuxWorkerNode,
Stop-LinuxWorkerNode,
Test-SupportedWorkerOS