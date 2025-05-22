Param(
    [string] $UserName = $(throw 'Argument missing: UserName'),
    [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
    [string] $NodeName,
    [string] $WindowsHostIpAddress = '',
    [string] $Proxy = '',
    [switch] $ShowLogs = $false
)

$durationStopwatch = [system.diagnostics.stopwatch]::StartNew()

$infraModule =   "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule =    "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

$ErrorActionPreference = 'Stop'

# Set installation path
$installationPath = Get-KubePath
Set-Location $installationPath

# Pre-requisites check
Write-Log "Performing pre-requisites check windows" -Console

$connectionCheck = (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'powershell.exe -Command "Get-Command"' -UserName $UserName -IpAddress $IpAddress)
if (!$connectionCheck.Success) {
    throw "Cannot connect to node with IP '$IpAddress'. Error message: $($connectionCheck.Output)"
}

# Public key check
$localPublicKeyFilePath = "$(Get-SSHKeyControlPlane).pub"
if (!(Test-Path -Path $localPublicKeyFilePath)) {
    throw "Precondition not met: the file '$localPublicKeyFilePath' shall exist."
}
$localPublicKey = (Get-Content -Raw $localPublicKeyFilePath).Trim()
if ([string]::IsNullOrWhiteSpace($localPublicKey)) {
    throw "Precondition not met: the file '$localPublicKeyFilePath' is not empty."
}
$authorizedKeysFilePath = "C:\Users\$UserName\.ssh\authorized_keys"

$authorizedKeys = (Invoke-CmdOnVmViaSSHKey -CmdToExecute "powershell.exe Get-Content $authorizedKeysFilePath" -UserName $UserName -IpAddress $IpAddress).Output
# $authorizedKeys = (Invoke-CmdOnVmViaSSHKey -CmdToExecute "if (Test-Path $authorizedKeysFilePath) { Get-Content $authorizedKeysFilePath } else { 'File $authorizedKeysFilePath not available' }" -UserName $UserName -IpAddress $IpAddress).Output
if (!($authorizedKeys.Contains($localPublicKey))) {
    throw "Precondition not met: the local public key from the file '$localPublicKeyFilePath' is present in the file '$authorizedKeysFilePath' of the computer with IP '$IpAddress'."
}

# Hostname check
$actualHostname = (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'powershell.exe -Command "hostname"' -UserName $UserName -IpAddress $IpAddress).Output.Trim()

$k8sFormattedNodeName = $actualHostname.ToLower()

if (![string]::IsNullOrWhiteSpace($NodeName) -and ($NodeName.ToLower() -ne $k8sFormattedNodeName)) {
    throw "Precondition not met: the passed NodeName '$NodeName' is the hostname of the computer with IP '$IpAddress' ($actualHostname)"
}

$NodeName = $actualHostname

# Cluster membership check
$clusterState = (Invoke-Kubectl -Params @('get', 'nodes', '-o', 'wide')).Output
if ($clusterState -match $k8sFormattedNodeName) {
    throw "Precondition not met: the node '$k8sFormattedNodeName' is already part of the cluster."
}

# Determine Windows Host IP Address
if ($WindowsHostIpAddress -eq '') {
    $loopbackAdapter = Get-L2BridgeName
    $WindowsHostIpAddress = Get-HostPhysicalIp -ExcludeNetworkInterfaceName $loopbackAdapter
}
Write-Log "Windows Host IP address: $WindowsHostIpAddress"

# Retrieve proxy configuration
if ($Proxy -eq '') {
    $proxyConfig = Get-ProxyConfig
    $Proxy = $proxyConfig.HttpProxy
}

# Add Windows worker node
$workerNodeParams = @{
    NodeName = $NodeName
    UserName = $UserName
    IpAddress = $IpAddress
    WindowsHostIpAddress = $WindowsHostIpAddress
    Proxy = $Proxy
    AdditionalHooksDir= $AdditionalHooksDir
}
Add-WindowsWorkerNodeOnWindowsHostRemote @workerNodeParams

# Start worker node
Write-Log 'Starting worker node' -Console
& "$PSScriptRoot\Start.ps1" -ShowLogs:$ShowLogs -SkipHeaderDisplay -IpAddress $IpAddress -NodeName $NodeName

# Log cluster state
Write-Log "Current state of cluster nodes:" -Console
Start-Sleep 2
$kubeToolsPath = Get-KubeToolsPath
&"$kubeToolsPath\kubectl.exe" get nodes -o wide 2>&1 | ForEach-Object { "$_" } | Write-Log -Console

# Completion message
Write-Log '---------------------------------------------------------------'
Write-Log "Windows computer with IP '$IpAddress' and hostname '$NodeName' added to the cluster.   Total duration: $('{0:hh\:mm\:ss}' -f $durationStopwatch.Elapsed )"
Write-Log '---------------------------------------------------------------'