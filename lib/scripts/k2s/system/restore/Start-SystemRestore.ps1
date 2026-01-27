param(
    [string] $BackupFile,
    [switch] $ShowLogs = $false,
    [switch] $ErrorOnFailure = $false,
    [string] $AdditionalHooksDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Modules
Import-Module (Join-Path $PSScriptRoot "..\..\..\..\modules\k2s\k2s.cluster.module\upgrade\upgrade.module.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "..\..\..\..\modules\k2s\k2s.cluster.module\setupinfo\setupinfo.module.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "..\..\..\..\modules\k2s\k2s.cluster.module\runningstate\runningstate.module.psm1") -Force


# ------------------------------------------------------------
# Verify K2s is installed
# ------------------------------------------------------------
$setupInfo = Get-SetupInfo
if ($null -eq $setupInfo -or -not $setupInfo.Name) {
    throw "K2s is not installed. Please run 'k2s install' first."
}

Write-Log "Starting system restore" -Console

if (-not (Test-Path $BackupFile)) {
    throw "Backup file not found"
}

$restoreRoot = Get-TempPath
Write-Log "Using temp restore directory" -Console

try
{
    Write-Log "Extracting backup file: $BackupFile"
    Expand-Archive -Path $BackupFile -DestinationPath $restoreRoot -Force
} catch {
    Write-Log "[Restore] Failed to extract backup file: $_" -Console
    throw "Invalid or corrupt backup file. Failed to extract: $_"
}


$manifestPath = Join-Path $restoreRoot "backup.json"
if (-not (Test-Path $manifestPath)) {
    throw "Backup manifest (backup.json) not found in backup file. The backup may be incomplete or corrupted."
}

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

if ($manifest.apiVersion -ne "k2s.backup/v1") {
    throw "Unsupported backup apiVersion"
}

if ($manifest.kind -ne "SystemBackup") {
    throw "Invalid backup kind"
}

Enable-ClusterIsRunning -ShowLogs:$ShowLogs

# Restore config.json if present
if ($manifest.PSObject.Properties.Name -contains "configSnapshot") {
    $snap = $manifest.configSnapshot
    if ($snap -and ($snap.PSObject.Properties.Name -contains "content")) {

        Write-Log "Restoring config.json" -Console

        $kubePath = Get-KubePath
        $cfgDir = Join-Path $kubePath "cfg"
        $cfgFile = Join-Path $cfgDir "config.json"

        if (-not (Test-Path $cfgDir)) {
            New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
        }

        if (Test-Path $cfgFile) {
            Copy-Item $cfgFile ($cfgFile + ".bak") -Force
        }

        $snap.content | ConvertTo-Json -Depth 20 | Out-File $cfgFile -Encoding utf8
    }
}

$kubePath    = Get-KubePath
$kubectlPath = Get-KubeBinPathGivenKubePath -KubePathLocal $kubePath

$notNamespacedDir = Join-Path $restoreRoot "NotNamespaced"
$namespacedDir    = Join-Path $restoreRoot "Namespaced"

# ------------------------------------------------------------
# Restore cluster-scoped resources
# ------------------------------------------------------------
Write-Log "Restoring cluster-scoped resources" -Console

$clusterResult = Import-NotNamespacedResources `
    -folderResources $notNamespacedDir `
    -ExePath $kubectlPath `
    -ShowLogs:$ShowLogs `
    -ErrorOnFailure:$ErrorOnFailure

if ($ErrorOnFailure -and $clusterResult.Errors.Count -gt 0) {
    throw "Cluster-scoped resource restore failed"
}

# ------------------------------------------------------------
# Restore namespaced resources
# ------------------------------------------------------------
Write-Log "Restoring namespaced resources" -Console

$namespacedResult = Import-NamespacedResources `
    -folderNamespaces $namespacedDir `
    -ExePath $kubectlPath `
    -ShowLogs:$ShowLogs `
    -ErrorOnFailure:$ErrorOnFailure

# Report webhook-dependent failures that need addon re-enablement
if ($namespacedResult.WebhookFailures.Count -gt 0) {
    Write-Log "⚠️  Some resources require addons to be re-enabled:" -Console
    Write-Log "   - For example - Ingresses require 'ingress-nginx' addon" -Console
    Write-Log "   - For example - Certificates require 'cert-manager' addon" -Console
    Write-Log "   Run 'k2s addons enable <addon-name>' and then try restore again" -Console
}

if ($ErrorOnFailure -and $namespacedResult.Errors.Count -gt 0) {
    throw "Namespaced resource restore failed"
}


if (($clusterResult.Errors.Count -gt 0 -or $namespacedResult.Errors.Count -gt 0) -and $ErrorOnFailure) {
    throw "System restore finished with errors"
}


Write-Log "Running restore hooks" -Console
Invoke-UpgradeBackupRestoreHooks -HookType Restore -BackupDir (Join-Path $restoreRoot "hooks") -AdditionalHooksDir $AdditionalHooksDir

Write-Log "System restore completed" -Console
