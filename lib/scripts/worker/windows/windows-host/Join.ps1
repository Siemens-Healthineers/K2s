Param(
    [string]$JoinCommandFile = "C:\k2s\joincommand.txt",
    [string]$PodSubnetworkNumber = '1',
    [string]$AdditionalHooksDir = ''
)

$JoinCommand = Get-Content -Path $JoinCommandFile -Raw

$infraModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
Import-Module $infraModule, $clusterModule

Write-Log "Invoking Initialize-KubernetesCluster with JoinCommand: $JoinCommand"
Initialize-KubernetesCluster -AdditionalHooksDir $AdditionalHooksDir -PodSubnetworkNumber $PodSubnetworkNumber -JoinCommand $JoinCommand