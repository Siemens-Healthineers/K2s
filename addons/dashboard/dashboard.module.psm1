# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule

function Get-HeadlampManifestsDirectory {
    return "$PSScriptRoot\manifests\headlamp"
}

function Get-HeadlampChartDirectory {
    return "$PSScriptRoot\manifests\chart"
}

function Get-HeadlampChartPath {
    $chartDir = Get-HeadlampChartDirectory
    $charts = @(Get-ChildItem -Path $chartDir -Filter 'headlamp-*.tgz' -ErrorAction SilentlyContinue)
    if ($charts.Count -eq 0) {
        return $null
    }
    return $charts[0].FullName
}

function Install-HeadlampViaHelm {
    $chartDir = Get-HeadlampChartDirectory
    $chartPath = Get-HeadlampChartPath
    if ($null -eq $chartPath) {
        throw '[Dashboard] No headlamp Helm chart .tgz found in manifests/chart/'
    }
    $valuesPath = Join-Path $chartDir 'values.yaml'
    if (-not (Test-Path $valuesPath)) {
        throw "[Dashboard] values.yaml not found at '$valuesPath'"
    }

    $nsExists = (Invoke-Kubectl -Params 'get', 'namespace', 'dashboard', '--ignore-not-found').Output
    if (-not $nsExists) {
        Write-Log '[Dashboard] Creating dashboard namespace' -Console
        (Invoke-Kubectl -Params 'create', 'namespace', 'dashboard').Output | Write-Log
        (Invoke-Kubectl -Params 'label', 'namespace', 'dashboard', 'app.kubernetes.io/name=headlamp', '--overwrite').Output | Write-Log
    }

    Write-Log "[Dashboard] Installing Headlamp via Helm chart: $(Split-Path $chartPath -Leaf)" -Console
    $helmResult = Invoke-Helm -Params @(
        'upgrade', '--install', 'headlamp', $chartPath,
        '--namespace', 'dashboard',
        '--values', $valuesPath
    )
    $helmResult.Output | Write-Log
    if (-not $helmResult.Success) {
        throw '[Dashboard] helm upgrade --install failed. See log for details.'
    }
}

function Uninstall-HeadlampViaHelm {
    $releaseExists = (Invoke-Helm -Params @('list', '-n', 'dashboard', '-q')).Output
    if ($releaseExists -match 'headlamp') {
        Write-Log '[Dashboard] Uninstalling Headlamp Helm release' -Console
        $helmResult = Invoke-Helm -Params @('uninstall', 'headlamp', '--namespace', 'dashboard', '--wait', '--timeout', '2m0s')
        $helmResult.Output | Write-Log
        if (-not $helmResult.Success) {
            Write-Log '[Dashboard] Warning: helm uninstall returned non-zero; continuing cleanup' -Console
        }
    }
    else {
        Write-Log '[Dashboard] No headlamp Helm release found; skipping helm uninstall' -Console
    }

    (Invoke-Kubectl -Params 'delete', 'clusterrolebinding', 'headlamp-admin', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'namespace', 'dashboard', '--ignore-not-found').Output | Write-Log
}

function Enable-MetricsServer {
    &"$PSScriptRoot\..\metrics\Enable.ps1" -ShowLogs:$ShowLogs
}

function Wait-ForHeadlampAvailable {
    return (Wait-ForPodCondition -Condition Ready -Label 'app.kubernetes.io/name=headlamp' -Namespace 'dashboard' -TimeoutSeconds 200)
}

####################################################################################################
# Headlamp plugin injection (init-container pattern)
# See headlamp-plugins-design.md for full design rationale.
####################################################################################################

<#
.SYNOPSIS
Builds a single init-container hashtable for injecting a compiled Headlamp plugin.
#>
function New-PluginInitContainer {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)] [string] $Name,
        [Parameter(Mandatory = $true)] [string] $Image
    )
    return @{
        name            = $Name
        image           = $Image
        imagePullPolicy = 'IfNotPresent'
        command         = @('sh', '-c', 'cp -r /plugins/. /headlamp-plugins/')
        volumeMounts    = @(
            @{ name = 'headlamp-plugins'; mountPath = '/headlamp-plugins' }
        )
        securityContext = @{
            allowPrivilegeEscalation = $false
            runAsNonRoot             = $false
            seccompProfile           = @{ type = 'RuntimeDefault' }
            capabilities             = @{ drop = @('ALL') }
        }
    }
}

<#
.SYNOPSIS
Patches the Headlamp deployment with the supplied init-container set and waits for rollout.
Pass an empty array to remove all plugin init-containers.
#>
function Apply-HeadlampPluginPatch {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $InitContainers
    )

    # ── Short-circuit: nothing to do when no plugins are active and none were
    # previously injected. Avoid patching a fresh Helm deployment with an empty
    # initContainers list — strategic-merge would still mutate the deployment
    # spec and the headlamp-plugins volume/mount may not exist yet, causing
    # "patch failed" errors on a clean install.
    if ($InitContainers.Count -eq 0) {
        # Only run cleanup patches when the volume/mount actually exists already
        # (i.e. plugins were previously injected).  We detect this by checking
        # whether the headlamp-plugins volume is present in the live deployment.
        $liveJson = (Invoke-Kubectl -Params 'get', 'deployment', 'headlamp',
            '-n', 'dashboard', '-o', 'json', '--ignore-not-found').Output
        $pluginsVolumePresent = $false
        if (-not [string]::IsNullOrWhiteSpace($liveJson)) {
            try {
                $live = $liveJson | ConvertFrom-Json
                $pluginsVolumePresent = ($live.spec.template.spec.volumes |
                    Where-Object { $_.name -eq 'headlamp-plugins' } | Measure-Object).Count -gt 0
            } catch { }
        }

        if (-not $pluginsVolumePresent) {
            Write-Log '[Dashboard] No plugins active and no prior injection detected — skipping patch.' -Console
            return
        }

        Write-Log '[Dashboard] Removing Headlamp plugin injection (all plugins disabled)...' -Console

        # Remove initContainers and the shared plugins volume
        $clearPatch = @'
{
  "spec": {
    "template": {
      "spec": {
        "initContainers": [],
        "volumes": [
          { "$patch": "delete", "name": "headlamp-plugins" }
        ]
      }
    }
  }
}
'@
        $rc = Invoke-Kubectl -Params 'patch', 'deployment', 'headlamp', '-n', 'dashboard', '--type', 'strategic', '-p', $clearPatch
        $rc.Output | Write-Log
        if (-not $rc.Success) {
            Write-Log '[Dashboard] Warning: could not remove plugin initContainers/volume; continuing.' -Console
        }

        # Remove the volume-mount from the main headlamp container
        $removeMountPatch = @'
{
  "spec": {
    "template": {
      "spec": {
        "containers": [
          {
            "name": "headlamp",
            "volumeMounts": [
              { "$patch": "delete", "name": "headlamp-plugins" }
            ]
          }
        ]
      }
    }
  }
}
'@
        $rm = Invoke-Kubectl -Params 'patch', 'deployment', 'headlamp', '-n', 'dashboard', '--type', 'strategic', '-p', $removeMountPatch
        $rm.Output | Write-Log
        # Ignore failure — mount may already be absent

        Write-Log '[Dashboard] Waiting for Headlamp rollout after plugin removal...' -Console
        (Invoke-Kubectl -Params 'rollout', 'status', 'deployment', 'headlamp', '-n', 'dashboard', '--timeout', '180s').Output | Write-Log
        return
    }

    # ── At least one plugin is active: inject initContainers + shared volume ──

    # Build a guaranteed-array JSON string for initContainers.
    # ConvertTo-Json collapses a 1-element array to an object in PS5.
    # Workaround: serialise each element individually, join, wrap in [].
    $arr = @($InitContainers)
    $elementJsons = $arr | ForEach-Object { $_ | ConvertTo-Json -Depth 20 -Compress }
    $initJson = '[' + ($elementJsons -join ',') + ']'

    # ── Patch 1 — write to temp file to avoid PS string-quoting issues ────────
    $patch1obj = [ordered]@{
        spec = [ordered]@{
            template = [ordered]@{
                spec = [ordered]@{
                    volumes        = @(@{ name = 'headlamp-plugins'; emptyDir = @{} })
                    initContainers = $arr
                }
            }
        }
    }
    # Manually build the JSON so initContainers is always an array
    $patch1json = "{`"spec`":{`"template`":{`"spec`":{`"volumes`":[{`"name`":`"headlamp-plugins`",`"emptyDir`":{}}],`"initContainers`":$initJson}}}}"
    $tmpPatch1 = [System.IO.Path]::GetTempFileName() + '.json'
    $patch1json | Set-Content $tmpPatch1 -Encoding UTF8

    Write-Log "[Dashboard] Patching headlamp deployment (initContainers: $($arr.Count))" -Console
    $r = Invoke-Kubectl -Params 'patch', 'deployment', 'headlamp', '-n', 'dashboard', '--type', 'strategic', "--patch-file=$tmpPatch1"
    $r.Output | Write-Log
    Remove-Item $tmpPatch1 -Force -ErrorAction SilentlyContinue
    if (-not $r.Success) { throw '[Dashboard] headlamp plugin patch (initContainers) failed' }

    # ── Patch 2 (strategic-merge): volume-mount on the main headlamp container ─
    $patch2 = @'
{
  "spec": {
    "template": {
      "spec": {
        "containers": [
          {
            "name": "headlamp",
            "volumeMounts": [
              { "name": "headlamp-plugins", "mountPath": "/tmp/headlamp/plugins" }
            ]
          }
        ]
      }
    }
  }
}
'@
    $tmpPatch2 = [System.IO.Path]::GetTempFileName() + '.json'
    $patch2 | Set-Content $tmpPatch2 -Encoding UTF8
    $mr = Invoke-Kubectl -Params 'patch', 'deployment', 'headlamp', '-n', 'dashboard', '--type', 'strategic', "--patch-file=$tmpPatch2"
    $mr.Output | Write-Log
    Remove-Item $tmpPatch2 -Force -ErrorAction SilentlyContinue
    if (-not $mr.Success) { throw '[Dashboard] headlamp plugin patch (volumeMount) failed' }

    Write-Log '[Dashboard] Waiting for Headlamp rollout after plugin patch...' -Console
    (Invoke-Kubectl -Params 'rollout', 'status', 'deployment', 'headlamp', '-n', 'dashboard', '--timeout', '180s').Output | Write-Log
}

<#
.SYNOPSIS
Detects which plugin-capable addons are enabled and syncs the Headlamp plugin init-containers.
Idempotent — safe to call from any addon Enable.ps1 / Disable.ps1.
#>
function Sync-HeadlampPlugins {
    [CmdletBinding()]
    Param()

    $headlampPresent = (Invoke-Kubectl -Params 'get', 'deployment', 'headlamp', '-n', 'dashboard',
        '--ignore-not-found', '--no-headers').Output
    if ([string]::IsNullOrWhiteSpace($headlampPresent)) {
        Write-Log '[Dashboard] Headlamp not present — skipping plugin sync' -Console
        return
    }

    Write-Log '[Dashboard] Syncing Headlamp plugins...' -Console

    $fluxEnabled        = Test-IsAddonEnabled -Addon ([pscustomobject]@{ Name = 'rollout';      Implementation = 'fluxcd' })
    $securityEnabled    = Test-IsAddonEnabled -Addon ([pscustomobject]@{ Name = 'security' })
    $monitoringEnabled  = Test-IsAddonEnabled -Addon ([pscustomobject]@{ Name = 'monitoring' })

    $containers = @()
    if ($fluxEnabled)       { $containers += New-PluginInitContainer -Name 'flux-plugin'          -Image 'shsk2s.azurecr.io/headlamp-plugin-flux:0.6.0' }
    if ($securityEnabled)   { $containers += New-PluginInitContainer -Name 'cert-manager-plugin'  -Image 'shsk2s.azurecr.io/headlamp-plugin-cert-manager:0.1.0' }
    if ($monitoringEnabled) { $containers += New-PluginInitContainer -Name 'prometheus-plugin'    -Image 'shsk2s.azurecr.io/headlamp-plugin-prometheus:0.8.2' }

    Apply-HeadlampPluginPatch -InitContainers $containers
    Write-Log "[Dashboard] Plugin sync complete ($($containers.Count) plugin(s) active)" -Console
}

####################################################################################################

function Write-HeadlampUsageForUser {
    @"
                DASHBOARD ADDON (Headlamp) - USAGE NOTES
 To open the Headlamp dashboard, please use one of the options:

 Option 1: Access via ingress
 Please install either ingress nginx, ingress traefik, or ingress nginx gateway addon from k2s.
 or you can install them on your own.
 Enable ingress controller via k2s cli
 eg. k2s addons enable ingress nginx
 Once the ingress controller is running in the cluster, run the command to enable dashboard
 k2s addons enable dashboard
 The Headlamp dashboard will be accessible on the following URL: https://k2s.cluster.local/dashboard/

 Option 2: Port-forwarding
 Use port-forwarding to the headlamp service using the command below:
 kubectl port-forward svc/headlamp -n dashboard 4466:4466

 In this case, the Headlamp dashboard will be accessible on the following URL: http://localhost:4466/dashboard/
 It is not necessary to use port 4466. Please feel free to use a port number of your choice.

 NOTE: Headlamp will show a token login screen - this is expected and normal.
 To log in, generate a ServiceAccount token with the command below and paste it into the login screen:
    kubectl -n dashboard create token headlamp --duration 24h

 Read more: https://headlamp.dev/docs/latest/
"@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
}

Export-ModuleMember -Function Get-HeadlampManifestsDirectory, Get-HeadlampChartDirectory, Get-HeadlampChartPath, Install-HeadlampViaHelm, Uninstall-HeadlampViaHelm, Enable-MetricsServer, Wait-ForHeadlampAvailable, Write-HeadlampUsageForUser, New-PluginInitContainer, Apply-HeadlampPluginPatch, Sync-HeadlampPlugins
