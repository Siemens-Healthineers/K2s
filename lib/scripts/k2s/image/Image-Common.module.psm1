# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

$infraModule = "$PSScriptRoot/../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$nodeModule = "$PSScriptRoot/../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"

# -Global ensures functions from these modules are visible to scripts that import this module
Import-Module $infraModule, $clusterModule, $nodeModule -Global

<#
.SYNOPSIS
Tests whether a Kubernetes node is in Ready state.

.DESCRIPTION
Uses kubectl to check if the node is reporting Ready status.
Returns $true if the node is Ready, $false otherwise.
For control-plane and local Windows host, always returns $true (they must be Ready for the cluster to be up).

.PARAMETER NodeName
The name of the node to check.

.PARAMETER Kind
The kind of node (ControlPlane, LinuxWorker, LocalWindows, WindowsWorker).
#>
function Test-NodeReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NodeName,
        [Parameter(Mandatory = $false)]
        [string]$Kind = ''
    )

    # Control-plane and local Windows host are implicitly Ready if we got this far (cluster is running)
    if ($Kind -in @('ControlPlane', 'LocalWindows')) {
        return $true
    }

    try {
        $kubePath = Get-KubePath
        $kubectlExe = "$kubePath\bin\kube\kubectl.exe"
        $nodeStatus = & $kubectlExe get node $NodeName --no-headers 2>&1 | Out-String
        if (-not [string]::IsNullOrWhiteSpace($nodeStatus) -and $nodeStatus -match '\s+Ready(?:\s|,|$)') {
            return $true
        }
    }
    catch {
        Write-Log "[NodeReady] Error checking status for node '$NodeName': $_"
    }

    return $false
}

<#
.SYNOPSIS
Initializes image script runtime (logging + system availability check).

.DESCRIPTION
- Initializes logging with optional console output.
- Checks system availability.
- On structured mode, forwards system error to CLI and returns $false.
- On non-structured mode, logs error and exits with code 1.
#>
function Initialize-ImageScriptContext {
    param(
        [Parameter(Mandatory = $false)]
        [switch]$ShowLogs = $false,
        [Parameter(Mandatory = $false)]
        [switch]$EncodeStructuredOutput,
        [Parameter(Mandatory = $false)]
        [string]$MessageType
    )

    Initialize-Logging -ShowLogs:$ShowLogs

    $systemError = Test-SystemAvailability -Structured
    if ($systemError) {
        if ($EncodeStructuredOutput -eq $true) {
            Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
            return $false
        }

        Write-Log $systemError.Message -Error
        exit 1
    }

    return $true
}

<#
.SYNOPSIS
Resolves a node name to its metadata (OS, kind, and connection details).

.DESCRIPTION
Checks in order:
  1. Local Windows host  (matches $env:ComputerName)
  2. Linux control-plane (matches ControlPlaneNodeHostname from setup.json)
  3. Remote node from cluster descriptor (cluster.json)

Returns a hashtable with keys:
  Name      - node name (lowercase)
  OS        - 'linux' | 'windows'
  Kind      - 'ControlPlane' | 'LinuxWorker' | 'LocalWindows' | 'WindowsWorker'
  IpAddress - SSH target IP  (Linux workers only)
  Username  - SSH username   (Linux workers only)
  NodeType  - NodeType value from cluster.json (e.g. 'HOST', 'VM-EXISTING')

Returns $null if the node cannot be resolved.
#>
function Resolve-ImageNode {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NodeName
    )

    $nodeLower = $NodeName.ToLower()
    $localWindowsName = $env:ComputerName.ToLower()

    # 1. Local Windows host
    if ($nodeLower -eq $localWindowsName) {
        Write-Log "[ImageNode] '$nodeLower' identified as local Windows host"
        return @{
            Name     = $nodeLower
            OS       = 'windows'
            Kind     = 'LocalWindows'
            NodeType = 'HOST'
        }
    }

    # 2. Linux control-plane
    $setupFilePath = Get-SetupConfigFilePath
    $controlPlaneHostname = Get-ConfigValue -Path $setupFilePath -Key 'ControlPlaneNodeHostname'
    if ([string]::IsNullOrWhiteSpace($controlPlaneHostname)) {
        $controlPlaneHostname = 'kubemaster'
    }

    if ($nodeLower -eq $controlPlaneHostname.ToLower()) {
        Write-Log "[ImageNode] '$nodeLower' identified as Linux control-plane"
        return @{
            Name = $nodeLower
            OS   = 'linux'
            Kind = 'ControlPlane'
        }
    }

    # 3. Remote node from cluster descriptor
    $clusterNode = Get-NodeConfig -NodeName $NodeName
    if ($null -eq $clusterNode) {
        Write-Log "[ImageNode] '$NodeName' not found in cluster descriptor"
        return $null
    }

    $nodeOs = "$($clusterNode.OS)".ToLower()

    if ($nodeOs -eq 'linux') {
        if ([string]::IsNullOrWhiteSpace($clusterNode.IpAddress) -or [string]::IsNullOrWhiteSpace($clusterNode.Username)) {
            Write-Log "[ImageNode] '$NodeName' is a Linux worker but IpAddress or Username is missing in cluster descriptor"
            return $null
        }
        Write-Log "[ImageNode] '$nodeLower' identified as Linux worker (IP=$($clusterNode.IpAddress))"
        return @{
            Name      = $nodeLower
            OS        = 'linux'
            Kind      = 'LinuxWorker'
            IpAddress = $clusterNode.IpAddress
            Username  = $clusterNode.Username
            NodeType  = $clusterNode.NodeType
        }
    }

    if ($nodeOs -eq 'windows') {
        Write-Log "[ImageNode] '$nodeLower' identified as Windows worker (NodeType=$($clusterNode.NodeType))"
        return @{
            Name     = $nodeLower
            OS       = 'windows'
            Kind     = 'WindowsWorker'
            NodeType = $clusterNode.NodeType
        }
    }

    Write-Log "[ImageNode] '$NodeName' has unsupported OS '$nodeOs' in cluster descriptor"
    return $null
}

<#
.SYNOPSIS
Returns NodeInfo entries for the default nodes queried when no --node filter is given.

.DESCRIPTION
The default set is: control-plane (Linux) + local Windows host.
Both are resolved via Resolve-ImageNode so the same routing logic applies.
#>
function Get-DefaultNodeInfoList {
    $setupFilePath = Get-SetupConfigFilePath
    $controlPlaneHostname = Get-ConfigValue -Path $setupFilePath -Key 'ControlPlaneNodeHostname'
    if ([string]::IsNullOrWhiteSpace($controlPlaneHostname)) {
        $controlPlaneHostname = 'kubemaster'
    }

    $defaultNodes = @(
        (Resolve-ImageNode -NodeName $controlPlaneHostname),
        (Resolve-ImageNode -NodeName $env:ComputerName)
    )

    return @($defaultNodes | Where-Object { $null -ne $_ })
}

<#
.SYNOPSIS
Lists container images on a resolved node by executing the correct command.

.DESCRIPTION
Routes to the matching execution path based on NodeInfo.Kind:

  ControlPlane  → SSH to control-plane  → sudo buildah images
  LinuxWorker   → SSH to worker node    → sudo buildah images
  LocalWindows  → local process         → crictl images
  WindowsWorker → remote session        → crictl images (remote)

Returns an array of ContainerImage objects.
#>
function Get-ImagesOnNode {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$NodeInfo,
        [Parameter(Mandatory = $false)]
        [bool]$IncludeK8sImages = $false,
        [Parameter(Mandatory = $false)]
        [bool]$ExcludeAddonImages = $false,
        [Parameter(Mandatory = $false)]
        [string]$CrictlExePath = '',
        [Parameter(Mandatory = $false)]
        [string]$CrictlConfigPath = ''
    )

    switch ($NodeInfo.Kind) {
        'ControlPlane' {
            Write-Log "[ImageNode] Executing 'sudo buildah images' on control-plane '$($NodeInfo.Name)'"
            return @(Get-ContainerImagesOnLinuxNode `
                    -IncludeK8sImages $IncludeK8sImages `
                    -ExcludeAddonImages $ExcludeAddonImages `
                    -NodeName $NodeInfo.Name)
        }
        'LinuxWorker' {
            Write-Log "[ImageNode] Executing 'sudo buildah images' on Linux worker '$($NodeInfo.Name)' ($($NodeInfo.IpAddress))"
            return @(Get-ContainerImagesOnLinuxNode `
                    -IncludeK8sImages $IncludeK8sImages `
                    -ExcludeAddonImages $ExcludeAddonImages `
                    -IpAddress $NodeInfo.IpAddress `
                    -UserName $NodeInfo.Username `
                    -NodeName $NodeInfo.Name)
        }
        'LocalWindows' {
            Write-Log "[ImageNode] Executing 'crictl images' on local Windows host '$($NodeInfo.Name)'"
            return @(Get-ContainerImagesOnWindowsNode `
                    -IncludeK8sImages $IncludeK8sImages `
                    -ExcludeAddonImages $ExcludeAddonImages `
                    -NodeName $NodeInfo.Name `
                    -NodeType 'HOST' `
                    -CrictlExePath $CrictlExePath `
                    -CrictlConfigPath $CrictlConfigPath)
        }
        'WindowsWorker' {
            Write-Log "[ImageNode] Executing 'crictl images' on Windows worker '$($NodeInfo.Name)' via remote session"
            return @(Get-ContainerImagesOnWindowsNode `
                    -IncludeK8sImages $IncludeK8sImages `
                    -ExcludeAddonImages $ExcludeAddonImages `
                    -NodeName $NodeInfo.Name `
                    -NodeType $NodeInfo.NodeType `
                    -CrictlExePath $CrictlExePath `
                    -CrictlConfigPath $CrictlConfigPath)
        }
        default {
            Write-Log "[ImageNode] Unknown node kind '$($NodeInfo.Kind)' for '$($NodeInfo.Name)'; returning empty list"
            return @()
        }
    }
}

<#
.SYNOPSIS
Parses the -Nodes / -Node script parameters into a normalized array of node names.

.DESCRIPTION
- Merges -Nodes (comma-separated) and -Node (single) into one list.
- Returns an empty array when neither parameter is given, which signals "use all default nodes".
#>
function Resolve-NodeList {
    param(
        [string]$Nodes = '',
        [string]$Node = ''
    )

    $combined = $Nodes
    if ([string]::IsNullOrWhiteSpace($combined)) {
        $combined = $Node
    }

    if ([string]::IsNullOrWhiteSpace($combined)) {
        return @()
    }

    return @($combined -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ -ne '' } | Select-Object -Unique)
}

<#
.SYNOPSIS
Collects images from selected nodes using shared node-orchestration flow.

.DESCRIPTION
- Uses default nodes (Linux control-plane and local Windows host) when no node selector is provided.
- Uses explicit node resolution when -Node/-Nodes are provided.
- Returns Linux, Windows and combined image arrays.
#>
function Get-ImagesByNodeSelection {
    param(
        [Parameter(Mandatory = $false)]
        [string]$Nodes = '',
        [Parameter(Mandatory = $false)]
        [string]$Node = '',
        [Parameter(Mandatory = $false)]
        [bool]$IncludeK8sImages = $false,
        [Parameter(Mandatory = $false)]
        [bool]$ExcludeAddonImages = $false,
        [Parameter(Mandatory = $false)]
        [string]$LogPrefix = 'ImageNode',
        [Parameter(Mandatory = $false)]
        [string]$CrictlExePath = '',
        [Parameter(Mandatory = $false)]
        [string]$CrictlConfigPath = ''
    )

    $nodeList = Resolve-NodeList -Nodes $Nodes -Node $Node
    Write-Log "[$LogPrefix] Node filter: $(if ($nodeList.Count -eq 0) { '<all default>' } else { $nodeList -join ', ' })"

    $targetNodeInfos = @()
    $skippedNodes = @()
    if ($nodeList.Count -eq 0) {
        $targetNodeInfos = @(Get-DefaultNodeInfoList)
    }
    else {
        foreach ($nodeName in $nodeList) {
            $nodeInfo = Resolve-ImageNode -NodeName $nodeName
            if ($null -eq $nodeInfo) {
                Write-Log "[$LogPrefix] Node '$nodeName' could not be resolved - verify the node name exists in the cluster" -Console
                $skippedNodes += @{ Name = $nodeName; Reason = 'not-found' }
                continue
            }
            # Check if node is Ready before adding to target list
            if (-not (Test-NodeReady -NodeName $nodeName -Kind $nodeInfo.Kind)) {
                Write-Log "[$LogPrefix] Node '$nodeName' is not in Ready state - start the node with 'k2s start --node $nodeName' first" -Console
                $skippedNodes += @{ Name = $nodeName; Reason = 'not-ready' }
                continue
            }
            $targetNodeInfos += $nodeInfo
        }
    }

    $linuxContainerImages = @()
    $windowsContainerImages = @()

    foreach ($nodeInfo in $targetNodeInfos) {
        Write-Log "[$LogPrefix] Querying images on '$($nodeInfo.Name)' (kind=$($nodeInfo.Kind), os=$($nodeInfo.OS))"
        $nodeImages = @(Get-ImagesOnNode -NodeInfo $nodeInfo -IncludeK8sImages $IncludeK8sImages -ExcludeAddonImages $ExcludeAddonImages -CrictlExePath $CrictlExePath -CrictlConfigPath $CrictlConfigPath)
        if ($nodeInfo.OS -eq 'linux') {
            $linuxContainerImages += $nodeImages
        }
        elseif ($nodeInfo.OS -eq 'windows') {
            $windowsContainerImages += $nodeImages
        }
    }

    return @{
        NodeInfos      = @($targetNodeInfos)
        SkippedNodes   = @($skippedNodes)
        LinuxImages    = @($linuxContainerImages)
        WindowsImages  = @($windowsContainerImages)
        AllImages      = @($linuxContainerImages) + @($windowsContainerImages)
    }
}

Export-ModuleMember -Function Initialize-ImageScriptContext, Resolve-ImageNode, Get-DefaultNodeInfoList, Get-ImagesOnNode, Resolve-NodeList, Get-ImagesByNodeSelection, Test-NodeReady
