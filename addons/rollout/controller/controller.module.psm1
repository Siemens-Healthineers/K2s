# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Shared helper module for deploying/removing the K2s GitOps Addon Controller.

.DESCRIPTION
Used by both fluxcd and argocd Enable/Disable/Get-Status scripts when the
--addongitops flag is set.
#>

$controllerDir = "$PSScriptRoot"

<#
.SYNOPSIS
Deploys the K2s GitOps Addon Controller (CRD, RBAC, DaemonSets).

.DESCRIPTION
Applies the K2sAddon CRD, RBAC resources, and Linux + Windows controller
DaemonSets, then waits for both controller pods to become Ready.

.OUTPUTS
Returns $null on success, or an error message string on failure.
#>
function Install-AddonGitOpsController {
    Write-Log '[AddonGitOps] Installing K2s addon controller' -Console

    # Determine the K2s install directory from the controller module location.
    # $controllerDir is <k2s_root>/addons/rollout/controller, so go up 3 levels.
    $k2sRoot = (Get-Item $controllerDir).Parent.Parent.Parent.FullName
    $windowsAddonsPath = "$k2sRoot\addons"
    Write-Log "[AddonGitOps] K2s root: $k2sRoot, Windows ADDONS_PATH: $windowsAddonsPath" -Console

    # Step 1: Apply CRD
    Write-Log '[AddonGitOps] Applying K2sAddon CRD' -Console
    $crdManifest = "$controllerDir\crds\k2saddon-crd.yaml"
    (Invoke-Kubectl -Params 'apply', '--server-side', '-f', $crdManifest).Output | Write-Log

    # Step 2: Apply RBAC
    Write-Log '[AddonGitOps] Applying controller RBAC' -Console
    $rbacManifest = "$controllerDir\manifests\rbac.yaml"
    (Invoke-Kubectl -Params 'apply', '--server-side', '-f', $rbacManifest).Output | Write-Log

    # Step 3: Deploy Linux DaemonSet
    Write-Log '[AddonGitOps] Deploying Linux controller DaemonSet' -Console
    $linuxDaemonset = "$controllerDir\manifests\daemonset-linux.yaml"
    (Invoke-Kubectl -Params 'apply', '-f', $linuxDaemonset).Output | Write-Log

    # Step 4: Deploy Windows DaemonSet and patch ADDONS_PATH to match K2s install directory.
    # The static YAML has a placeholder value; we override it here so the controller
    # writes addon files to the correct location that `k2s addons ls` scans.
    Write-Log '[AddonGitOps] Deploying Windows controller DaemonSet' -Console
    $windowsDaemonset = "$controllerDir\manifests\daemonset-windows.yaml"
    (Invoke-Kubectl -Params 'apply', '-f', $windowsDaemonset).Output | Write-Log
    Write-Log "[AddonGitOps] Patching Windows DaemonSet ADDONS_PATH to $windowsAddonsPath" -Console
    (Invoke-Kubectl -Params 'set', 'env', 'daemonset/k2s-addon-controller-windows', '-n', 'k2s-system', "ADDONS_PATH=$windowsAddonsPath").Output | Write-Log

    # Step 5: Wait for controller pods to be ready
    Write-Log '[AddonGitOps] Waiting for controller pods to be ready...' -Console
    $linuxReady = (Wait-ForPodCondition -Condition Ready -Label 'app.kubernetes.io/name=k2s-addon-controller,app.kubernetes.io/component=linux-processor' -Namespace 'k2s-system' -TimeoutSeconds 120)
    $windowsReady = (Wait-ForPodCondition -Condition Ready -Label 'app.kubernetes.io/name=k2s-addon-controller,app.kubernetes.io/component=windows-processor' -Namespace 'k2s-system' -TimeoutSeconds 120)

    if ($linuxReady -ne $true -or $windowsReady -ne $true) {
        return "Controller pods could not become ready. Please use 'kubectl describe pod -n k2s-system -l app.kubernetes.io/name=k2s-addon-controller' for more details."
    }

    Write-Log '[AddonGitOps] K2s addon controller installed successfully' -Console
    return $null
}

<#
.SYNOPSIS
Removes the K2s GitOps Addon Controller (K2sAddon CRs, DaemonSets, RBAC, CRD).

.DESCRIPTION
Deletes all K2sAddon custom resources (triggering finalizer cleanup), then removes
the DaemonSets, RBAC, and CRD in order.
#>
function Uninstall-AddonGitOpsController {
    Write-Log '[AddonGitOps] Uninstalling K2s addon controller' -Console

    # Step 1: Delete all K2sAddon CRs (triggers finalizers to clean up addon directories)
    Write-Log '[AddonGitOps] Deleting all K2sAddon custom resources' -Console
    (Invoke-Kubectl -Params 'delete', 'k2saddons', '--all', '--timeout', '60s', '--ignore-not-found').Output | Write-Log

    # Step 2: Remove DaemonSets
    Write-Log '[AddonGitOps] Removing controller DaemonSets' -Console
    $linuxDaemonset = "$controllerDir\manifests\daemonset-linux.yaml"
    $windowsDaemonset = "$controllerDir\manifests\daemonset-windows.yaml"
    (Invoke-Kubectl -Params 'delete', '-f', $windowsDaemonset, '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', '-f', $linuxDaemonset, '--ignore-not-found').Output | Write-Log

    # Step 3: Remove RBAC
    Write-Log '[AddonGitOps] Removing controller RBAC' -Console
    $rbacManifest = "$controllerDir\manifests\rbac.yaml"
    (Invoke-Kubectl -Params 'delete', '-f', $rbacManifest, '--ignore-not-found').Output | Write-Log

    # Step 4: Remove CRD
    Write-Log '[AddonGitOps] Removing K2sAddon CRD' -Console
    $crdManifest = "$controllerDir\crds\k2saddon-crd.yaml"
    (Invoke-Kubectl -Params 'delete', '-f', $crdManifest, '--ignore-not-found').Output | Write-Log

    Write-Log '[AddonGitOps] K2s addon controller removed' -Console
}

<#
.SYNOPSIS
Tests whether the K2s GitOps Addon Controller is currently deployed in the cluster.

.OUTPUTS
$true if the controller Linux DaemonSet exists in k2s-system, $false otherwise.
#>
function Test-AddonGitOpsControllerDeployed {
    $result = (Invoke-Kubectl -Params 'get', 'daemonset', 'k2s-addon-controller-linux', '-n', 'k2s-system', '--ignore-not-found', '-o', 'name')
    return [bool]$result.Output
}

<#
.SYNOPSIS
Returns status property objects for the K2s GitOps Addon Controller.

.DESCRIPTION
Checks the Linux DaemonSet, Windows DaemonSet, and K2sAddon CRD registration.
Returns an array of hashtable property objects matching the addon status pattern.

.PARAMETER ImplementationName
The implementation name (fluxcd or argocd) for constructing help messages.
#>
function Get-AddonGitOpsControllerStatus {
    param (
        [string] $ImplementationName = 'fluxcd'
    )

    $statusProps = @()

    # Check Linux controller DaemonSet
    $success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=jsonpath={.status.numberReady}=1',
        '-n', 'k2s-system', 'daemonset/k2s-addon-controller-linux' 2>&1)
    $linuxOk = $LASTEXITCODE -eq 0

    $prop = @{Name = 'IsLinuxControllerRunning'; Value = $linuxOk; Okay = $linuxOk }
    if ($linuxOk) {
        $prop.Message = 'Linux addon controller is working'
    }
    else {
        $prop.Message = "Linux addon controller is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable rollout $ImplementationName' and 'k2s addons enable rollout $ImplementationName -g'"
    }
    $statusProps += $prop

    # Check Windows controller DaemonSet
    $success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=jsonpath={.status.numberReady}=1',
        '-n', 'k2s-system', 'daemonset/k2s-addon-controller-windows' 2>&1)
    $windowsOk = $LASTEXITCODE -eq 0

    $prop = @{Name = 'IsWindowsControllerRunning'; Value = $windowsOk; Okay = $windowsOk }
    if ($windowsOk) {
        $prop.Message = 'Windows addon controller is working'
    }
    else {
        $prop.Message = "Windows addon controller is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable rollout $ImplementationName' and 'k2s addons enable rollout $ImplementationName -g'"
    }
    $statusProps += $prop

    # Check K2sAddon CRD is registered
    $crdResult = (Invoke-Kubectl -Params 'get', 'crd', 'k2saddons.k2s.siemens-healthineers.com' 2>&1)
    $crdOk = $LASTEXITCODE -eq 0

    $prop = @{Name = 'IsK2sAddonCRDRegistered'; Value = $crdOk; Okay = $crdOk }
    if ($crdOk) {
        $prop.Message = 'K2sAddon CRD is registered'
    }
    else {
        $prop.Message = "K2sAddon CRD is not registered. Try disabling and re-enabling the addon with 'k2s addons disable rollout $ImplementationName' and 'k2s addons enable rollout $ImplementationName -g'"
    }
    $statusProps += $prop

    return $statusProps
}

Export-ModuleMember -Function Install-AddonGitOpsController, Uninstall-AddonGitOpsController, Test-AddonGitOpsControllerDeployed, Get-AddonGitOpsControllerStatus
