# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

<#
.DESCRIPTION
	This module implements delta update functionality for K2s clusters.
	
	EXECUTION CONTEXT DETECTION:
	This module can run in two contexts:
	1. From installed k2s folder (e.g., C:\k\lib\modules\...) - uses relative paths
	2. From extracted delta package - expects modules already loaded by Start-ClusterUpdate.ps1
	
	When running from delta package:
	- Start-ClusterUpdate.ps1 detects delta context and loads modules from target installation
	- This module skips duplicate module loading
	- References the existing installation via Get-ClusterInstalledFolder for source/state operations
	- Completes the delta package directory and switches setup.json InstallFolder to it
#>

# Detect if we're running from a delta package (extracted) or from installed k2s
# If delta-manifest.json exists 5 levels up, we're in a delta package
$deltaManifestCheck = Join-Path (Split-Path (Split-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) -Parent) -Parent) 'delta-manifest.json'
$runningFromDelta = Test-Path -LiteralPath $deltaManifestCheck

if ($runningFromDelta) {
	# Running from delta package - modules should already be loaded by Start-ClusterUpdate.ps1
	# No need to import again, but verify key functions are available
	if (-not (Get-Command -Name Write-Log -ErrorAction SilentlyContinue)) {
		Write-Warning "[Update] Running from delta package but Write-Log not available - modules may not be loaded"
	}
	$script:DeferredModuleLoad = $false  # Already loaded by caller
} else {
	# Running from installed k2s - use normal relative paths
	$infraModule = "$PSScriptRoot/../../k2s.infra.module/k2s.infra.module.psm1"
	Import-Module $infraModule
	
	# Import runningstate module for k2s running check
	$runningStateModule = "$PSScriptRoot/../runningstate/runningstate.module.psm1"
	Import-Module $runningStateModule
	$script:DeferredModuleLoad = $false
}

# Helper functions for version validation (from upgrade module)
function Get-ClusterInstalledFolder {
	$installFolder = Get-ConfigInstallFolder
	if ( [string]::IsNullOrEmpty($installFolder) ) {
		# we assume it is the old default
		$installFolder = 'C:\k'
	}
	return $installFolder
}

function Get-ProductVersionGivenKubePath {
	param (
		[Parameter(Mandatory = $false)]
		[string]$KubePathLocal = $(throw 'KubePath not specified')        
	)
	return "$(Get-Content -Raw -Path "$KubePathLocal\VERSION")".Trim()
}

function Get-TargetKubernetesVersionFromDebianDelta {
	param(
		[Parameter(Mandatory = $true)]
		[string] $DebianDeltaPath
	)

	$manifestPath = Join-Path $DebianDeltaPath 'debian-delta-manifest.json'
	if (Test-Path -LiteralPath $manifestPath) {
		try {
			$debianManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
			if (-not [string]::IsNullOrWhiteSpace($debianManifest.TargetKubernetesVersion)) {
				$version = [string]$debianManifest.TargetKubernetesVersion
				if (-not $version.StartsWith('v')) { $version = "v$version" }
				return $version
			}
		} catch {
			Write-Log ("[Update][Warn] Failed to read Debian delta manifest '{0}': {1}" -f $manifestPath, $_.Exception.Message) -Console
		}
	}

	$upgradedPath = Join-Path $DebianDeltaPath 'packages.upgraded'
	if (Test-Path -LiteralPath $upgradedPath) {
		foreach ($line in (Get-Content -LiteralPath $upgradedPath)) {
			if ($line -match '^(kubernetes|kubeadm|kubelet)\s+\S+\s+(?<target>v?\d+\.\d+\.\d+)') {
				$version = $matches['target']
				if (-not $version.StartsWith('v')) { $version = "v$version" }
				return $version
			}
		}
	}

	$imagesPath = Join-Path $DebianDeltaPath 'images'
	if (Test-Path -LiteralPath $imagesPath) {
		$image = Get-ChildItem -LiteralPath $imagesPath -File -Filter 'registry.k8s.io-kube-apiserver-v*.tar' -ErrorAction SilentlyContinue | Select-Object -First 1
		if ($image -and $image.Name -match 'registry\.k8s\.io-kube-apiserver-(?<target>v\d+\.\d+\.\d+)\.tar') {
			return $matches['target']
		}
	}

	return $null
}

function Set-K2sMachinePathEntries {
	param(
		[Parameter(Mandatory = $true)]
		[string] $OldKubePath,
		[Parameter(Mandatory = $true)]
		[string] $NewKubePath,
		[switch] $ShowLogs
	)

	$oldRoot = [IO.Path]::GetFullPath($OldKubePath).TrimEnd('\')
	$newRoot = [IO.Path]::GetFullPath($NewKubePath).TrimEnd('\')
	$oldEntries = @(
		$oldRoot,
		(Join-Path $oldRoot 'bin'),
		(Join-Path $oldRoot 'bin\kube'),
		(Join-Path $oldRoot 'bin\docker'),
		(Join-Path $oldRoot 'containerd'),
		(Join-Path $oldRoot 'bin\containerd')
	)
	$newEntries = @(
		$newRoot,
		(Join-Path $newRoot 'bin'),
		(Join-Path $newRoot 'bin\kube'),
		(Join-Path $newRoot 'bin\docker'),
		(Join-Path $newRoot 'bin\containerd')
	)
	$regLocation = 'Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment'
	$machinePath = (Get-ItemProperty -Path $regLocation -Name PATH).path
	$pathEntries = @($machinePath -split [IO.Path]::PathSeparator) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
	$filteredEntries = @()
	$removedCount = 0

	foreach ($entry in $pathEntries) {
		$trimmedEntry = $entry.Trim()
		$isOldEntry = $false
		foreach ($oldEntry in $oldEntries) {
			if ($trimmedEntry -ieq $oldEntry) {
				$isOldEntry = $true
				break
			}
		}
		if ($isOldEntry) {
			$removedCount++
			continue
		}
		$filteredEntries += $trimmedEntry
	}

	foreach ($newEntry in $newEntries) {
		if (-not ($filteredEntries | Where-Object { $_ -ieq $newEntry })) {
			$filteredEntries += $newEntry
		}
	}

	$deduplicatedEntries = @()
	foreach ($entry in $filteredEntries) {
		if (-not ($deduplicatedEntries | Where-Object { $_ -ieq $entry })) {
			$deduplicatedEntries += $entry
		}
	}

	$newMachinePath = $deduplicatedEntries -join [IO.Path]::PathSeparator
	Set-ItemProperty -Path $regLocation -Name PATH -Value $newMachinePath
	$machineEnv = [Environment]::GetEnvironmentVariable('Path', 'Machine')
	$userEnv = [Environment]::GetEnvironmentVariable('Path', 'User')
	$env:Path = (@($machineEnv, $userEnv) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [IO.Path]::PathSeparator
	Write-Log ("[Update] Updated machine PATH: removed {0} old K2s entries, ensured {1} new K2s entries" -f $removedCount, $newEntries.Count) -Console:$ShowLogs
}

<#
.SYNOPSIS
	Restores CoreDNS etcd plugin configuration after kubeadm upgrade.
.DESCRIPTION
	kubeadm upgrade may reset CoreDNS customizations. This function restores:
	- etcd TLS secrets (etcd-ca, etcd-client-for-core-dns)
	- CoreDNS ConfigMap etcd plugin block
	- CoreDNS Deployment volume mounts for etcd certificates
	
	This is required because K2s uses CoreDNS with an etcd plugin for external DNS
	resolution (see docs/op-manual/external-dns.md).
.PARAMETER ControlPlaneIp
	IP address of the control plane. Defaults to 172.19.1.100.
.PARAMETER ShowLogs
	Show detailed logs to console.
.OUTPUTS
	[bool] Success indicator.
.NOTES
	Requires Invoke-CmdOnControlPlaneViaSSHKey to be available (vm module).
#>
function Restore-CoreDnsEtcdConfiguration {
	[CmdletBinding()]
	param(
		[string]$ControlPlaneIp = '172.19.1.100',
		[switch]$ShowLogs
	)
	
	$consoleSwitch = $ShowLogs
	
	try {
		Write-Log "[CoreDNS] Restoring etcd plugin configuration..." -Console:$consoleSwitch
		Write-Log "[CoreDNS] Using control plane IP: $ControlPlaneIp" -Console:$consoleSwitch
		
		# Verify SSH helper is available
		if (-not (Get-Command -Name Invoke-CmdOnControlPlaneViaSSHKey -ErrorAction SilentlyContinue)) {
			$vmModule = "$PSScriptRoot/../../k2s.node.module/linuxnode/vm/vm.module.psm1"
			if (Test-Path -LiteralPath $vmModule) { 
				Import-Module $vmModule -ErrorAction SilentlyContinue 
			} else {
				$installFolder = Get-ClusterInstalledFolder
				$vmModule = Join-Path $installFolder 'lib/modules/k2s/k2s.node.module/linuxnode/vm/vm.module.psm1'
				if (Test-Path -LiteralPath $vmModule) {
					Import-Module $vmModule -ErrorAction SilentlyContinue
				}
			}
		}
		if (-not (Get-Command -Name Invoke-CmdOnControlPlaneViaSSHKey -ErrorAction SilentlyContinue)) {
			Write-Log "[CoreDNS][Error] SSH helper not available - vm module not found at $vmModule" -Console:$consoleSwitch
			return $false
		}
		
		# Step 1: Recreate etcd secrets for CoreDNS
		Write-Log "[CoreDNS] Recreating etcd secrets..." -Console:$consoleSwitch
		$certCopyResult = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'sudo mkdir -p /tmp/etcd-certs && sudo cp /etc/kubernetes/pki/etcd/* /tmp/etcd-certs/ && sudo chmod 444 /tmp/etcd-certs/*' -Timeout 30
		if (-not $certCopyResult.Success) {
			Write-Log "[CoreDNS][Error] Failed to copy etcd certificates: $($certCopyResult.Output)" -Console:$consoleSwitch
			return $false
		}
		
		$result = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl delete secret -n kube-system etcd-ca --ignore-not-found=true' -Timeout 30
		Write-Log "[CoreDNS] Delete old etcd-ca secret: Success=$($result.Success)" -Console:$consoleSwitch
		
		$result = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl delete secret -n kube-system etcd-client-for-core-dns --ignore-not-found=true' -Timeout 30
		Write-Log "[CoreDNS] Delete old etcd-client secret: Success=$($result.Success)" -Console:$consoleSwitch
		
		$result = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl create secret -n kube-system tls etcd-ca --cert=/tmp/etcd-certs/ca.crt --key=/tmp/etcd-certs/ca.key' -Timeout 30
		if (-not $result.Success) {
			Write-Log "[CoreDNS][Error] Failed to create etcd-ca secret: $($result.Output)" -Console:$consoleSwitch
			Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'sudo rm -rf /tmp/etcd-certs' -Timeout 10 -IgnoreErrors:$true | Out-Null
			return $false
		}
		Write-Log "[CoreDNS] Created etcd-ca secret" -Console:$consoleSwitch
		
		$result = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl create secret -n kube-system tls etcd-client-for-core-dns --cert=/tmp/etcd-certs/healthcheck-client.crt --key=/tmp/etcd-certs/healthcheck-client.key' -Timeout 30
		if (-not $result.Success) {
			Write-Log "[CoreDNS][Error] Failed to create etcd-client secret: $($result.Output)" -Console:$consoleSwitch
			Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'sudo rm -rf /tmp/etcd-certs' -Timeout 10 -IgnoreErrors:$true | Out-Null
			return $false
		}
		Write-Log "[CoreDNS] Created etcd-client-for-core-dns secret" -Console:$consoleSwitch
		
		Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'sudo rm -rf /tmp/etcd-certs' -Timeout 10 -IgnoreErrors:$true | Out-Null
		Write-Log "[CoreDNS] etcd secrets recreated" -Console:$consoleSwitch
		
		# Step 2: Update CoreDNS configmap to add etcd plugin if missing
		Write-Log "[CoreDNS] Checking CoreDNS configmap for etcd plugin..." -Console:$consoleSwitch
		$etcdPluginCheck = (Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl get configmap coredns -n kube-system -o yaml | grep -c "etcd cluster.local" || echo 0' -Timeout 30).Output
		if ($etcdPluginCheck -match '^0') {
			Write-Log "[CoreDNS] Adding etcd plugin to configmap..." -Console:$consoleSwitch
			$addEtcdPlugin = "kubectl get configmap coredns -n kube-system -o yaml | sed '/^\s*prometheus :9153/i\        etcd cluster.local {\n            path /skydns\n            endpoint https://${ControlPlaneIp}:2379\n            tls /etc/kubernetes/pki/etcd-client/tls.crt /etc/kubernetes/pki/etcd-client/tls.key /etc/kubernetes/pki/etcd-ca/tls.crt\n        }' | kubectl apply -f -"
			$result = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute $addEtcdPlugin -Timeout 30
			if (-not $result.Success) {
				Write-Log "[CoreDNS][Error] Failed to update configmap: $($result.Output)" -Console:$consoleSwitch
				return $false
			}
			Write-Log "[CoreDNS] etcd plugin added to configmap" -Console:$consoleSwitch
		} else {
			Write-Log "[CoreDNS] etcd plugin already present in configmap" -Console:$consoleSwitch
		}
		
		# Step 3: Update CoreDNS deployment to mount etcd certificate volumes if missing
		# Uses a single atomic kubectl patch to add both volumes AND mounts together,
		# avoiding the broken intermediate state where volumes exist without mounts.
		Write-Log "[CoreDNS] Checking CoreDNS deployment for etcd volume mounts..." -Console:$consoleSwitch
		$volumeCheck = (Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl get deployment coredns -n kube-system -o yaml | grep -c "etcd-ca-cert" || echo 0' -Timeout 30).Output
		if ($volumeCheck -match '^0') {
			Write-Log "[CoreDNS] Adding etcd volumes and mounts atomically via kubectl patch..." -Console:$consoleSwitch
			$patchJson = '[' +
				'{"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"etcd-ca-cert","secret":{"secretName":"etcd-ca"}}},' +
				'{"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"etcd-client-cert","secret":{"secretName":"etcd-client-for-core-dns"}}},' +
				'{"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"mountPath":"/etc/kubernetes/pki/etcd-ca","name":"etcd-ca-cert"}},' +
				'{"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"mountPath":"/etc/kubernetes/pki/etcd-client","name":"etcd-client-cert"}}' +
				']'
			# Base64-encode JSON to avoid double-quote stripping during PowerShell->ssh.exe transport
			$base64Json = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($patchJson))
			$patchCmd = "echo $base64Json | base64 -d | kubectl patch deployment coredns -n kube-system --type=json --patch-file=/dev/stdin"
			$result = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute $patchCmd -Timeout 30 -Retries 2
			if (-not $result.Success) {
				Write-Log "[CoreDNS][Error] Failed to patch deployment: $($result.Output)" -Console:$consoleSwitch
				return $false
			}
			Write-Log "[CoreDNS] Deployment patched with etcd volumes and mounts" -Console:$consoleSwitch
		} else {
			Write-Log "[CoreDNS] etcd volume mounts already present in deployment" -Console:$consoleSwitch
		}
		
		# Step 4: Restart CoreDNS and wait for it to become available
		Write-Log "[CoreDNS] Restarting CoreDNS deployment..." -Console:$consoleSwitch
		$result = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl rollout restart deployment/coredns -n kube-system' -Timeout 30
		if (-not $result.Success) {
			Write-Log "[CoreDNS][Warn] Rollout restart command failed: $($result.Output)" -Console:$consoleSwitch
		}
		
		$result = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl rollout status deployment/coredns -n kube-system --timeout=120s' -Timeout 150
		if (-not $result.Success) {
			Write-Log "[CoreDNS][Warn] Rollout did not complete within timeout: $($result.Output)" -Console:$consoleSwitch
		}
		
		# Step 5: Verify CoreDNS pods are actually running (not CrashLoopBackOff)
		Write-Log "[CoreDNS] Verifying CoreDNS pod health..." -Console:$consoleSwitch
		Start-Sleep -Seconds 10
		$podStatus = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl get pods -n kube-system -l k8s-app=kube-dns -o jsonpath=''{range .items[*]}{.status.phase} {.status.containerStatuses[0].ready}{"\n"}{end}''' -Timeout 30
		if ($podStatus.Success) {
			$statusLines = ($podStatus.Output -split "`n") | Where-Object { $_ -match '\S' }
			$allHealthy = $true
			foreach ($line in $statusLines) {
				if ($line -notmatch 'Running true') {
					$allHealthy = $false
					break
				}
			}
			if ($allHealthy -and $statusLines.Count -gt 0) {
				Write-Log "[CoreDNS] All CoreDNS pods healthy ($($statusLines.Count) pods running)" -Console:$consoleSwitch
			} else {
				Write-Log "[CoreDNS][Warn] Some CoreDNS pods may not be healthy:" -Console:$consoleSwitch
				$diagResult = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide' -Timeout 30
				Write-Log "[CoreDNS][Diag] $($diagResult.Output)" -Console:$consoleSwitch
				$logsResult = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl logs -n kube-system -l k8s-app=kube-dns --tail=20 --all-containers 2>&1' -Timeout 30
				Write-Log "[CoreDNS][Diag] Recent logs: $($logsResult.Output)" -Console:$consoleSwitch
			}
		} else {
			Write-Log "[CoreDNS][Warn] Could not verify pod health: $($podStatus.Output)" -Console:$consoleSwitch
		}
		
		Write-Log "[CoreDNS] Configuration restored successfully" -Console:$consoleSwitch
		return $true
	} catch {
		Write-Log ("[CoreDNS][Error] Restoration failed: {0}" -f $_.Exception.Message) -Console:$consoleSwitch
		Write-Log "[CoreDNS][Error] Manual restoration may be required - see docs/op-manual/external-dns.md" -Console:$consoleSwitch
		return $false
	}
}

<#
.SYNOPSIS
	Restores the ClusterIP mutating webhook after kubeadm upgrade.
.DESCRIPTION
	kubeadm upgrade apply may regenerate API server certificates and restart
	kube-apiserver. This can invalidate the webhook's TLS certificate chain
	(the caBundle in the MutatingWebhookConfiguration no longer matches the
	webhook's self-signed cert) or leave the webhook pod in a broken state.

	Because the webhook uses failurePolicy: Ignore, a broken webhook is
	silently skipped and Services get random ClusterIPs from the full /16
	service CIDR instead of the /24 subnets enforced by the webhook.

	The webhook Deployment uses an init container that generates a fresh TLS
	certificate on each Pod start. This function:
	1. Copies webhook manifests from the target installation to the control plane
	2. Re-applies namespace, RBAC and webhook configuration
	3. Applies the Deployment (with init-cert init container)
	4. Triggers a rollout restart to generate a fresh certificate
	5. Validates the webhook caBundle is set
.PARAMETER TargetInstallPath
	Path to the target K2s installation (e.g. C:\k).
.PARAMETER ShowLogs
	Show detailed logs to console.
.OUTPUTS
	[bool] Success indicator.
.NOTES
	Requires Invoke-CmdOnControlPlaneViaSSHKey and Copy-ToControlPlaneViaSSHKey
	to be available (vm module).
#>
function Restore-ClusterIPWebhook {
	[CmdletBinding()]
	param(
		[string]$TargetInstallPath = $(throw 'Argument missing: TargetInstallPath'),
		[switch]$ShowLogs
	)

	$consoleSwitch = $ShowLogs

	try {
		Write-Log '[Webhook] Restoring ClusterIP webhook after update...' -Console:$consoleSwitch

		# Verify SSH helpers are available
		if (-not (Get-Command -Name Invoke-CmdOnControlPlaneViaSSHKey -ErrorAction SilentlyContinue)) {
			$vmModule = "$PSScriptRoot/../../k2s.node.module/linuxnode/vm/vm.module.psm1"
			if (Test-Path -LiteralPath $vmModule) {
				Import-Module $vmModule -ErrorAction SilentlyContinue
			} else {
				$vmModule = Join-Path $TargetInstallPath 'lib/modules/k2s/k2s.node.module/linuxnode/vm/vm.module.psm1'
				if (Test-Path -LiteralPath $vmModule) {
					Import-Module $vmModule -ErrorAction SilentlyContinue
				}
			}
		}
		if (-not (Get-Command -Name Invoke-CmdOnControlPlaneViaSSHKey -ErrorAction SilentlyContinue)) {
			Write-Log '[Webhook][Error] SSH helper not available - vm module not found' -Console:$consoleSwitch
			return $false
		}

		# Locate webhook manifests in the target installation
		$manifestDir = Join-Path $TargetInstallPath 'lib\manifests\clusterip-webhook'
		if (-not (Test-Path -LiteralPath $manifestDir)) {
			Write-Log "[Webhook][Warn] Webhook manifests not found at $manifestDir - skipping" -Console:$consoleSwitch
			return $true
		}

		$remoteDir = '/tmp/clusterip-webhook-update'
		(Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute "mkdir -p $remoteDir" -Timeout 30 -IgnoreErrors:$true).Output | Out-Null

		# Copy manifest files to control plane
		$manifestFiles = @(
			'namespace.yaml',
			'rbac.yaml',
			'webhook-config.yaml',
			'deployment.yaml'
		)

		foreach ($file in $manifestFiles) {
			$localPath = Join-Path $manifestDir $file
			if (Test-Path -LiteralPath $localPath) {
				Copy-ToControlPlaneViaSSHKey -Source $localPath -Target "$remoteDir/" -IgnoreErrors:$false
			} else {
				Write-Log "[Webhook][Warn] Manifest file not found: $file" -Console:$consoleSwitch
			}
		}

		# Step 1: Apply namespace and RBAC
		Write-Log '[Webhook] Applying namespace and RBAC...' -Console:$consoleSwitch
		$nsResult = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute "kubectl apply -f $remoteDir/namespace.yaml" -Timeout 30 -Retries 3 -IgnoreErrors:$true
		Write-Log ('[Webhook] namespace apply: success={0} output={1}' -f $nsResult.Success, ($nsResult.Output | Out-String).Trim()) -Console:$consoleSwitch
		$rbacResult = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute "kubectl apply -f $remoteDir/rbac.yaml" -Timeout 30 -Retries 3 -IgnoreErrors:$true
		Write-Log ('[Webhook] rbac apply: success={0} output={1}' -f $rbacResult.Success, ($rbacResult.Output | Out-String).Trim()) -Console:$consoleSwitch

		# Step 2: Apply webhook configuration.
		# Note: This resets caBundle to "" in the MutatingWebhookConfiguration. The init container
		# in the deployment will re-patch it with a fresh CA certificate on rollout restart (Step 5).
		# There is a brief window between this apply and init container completion where the webhook
		# will not validate admission requests. This is safe because the webhook uses
		# failurePolicy: Ignore — admission requests are allowed through when the webhook is unavailable.
		Write-Log '[Webhook] Applying MutatingWebhookConfiguration...' -Console:$consoleSwitch
		(Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute "kubectl apply -f $remoteDir/webhook-config.yaml" -Timeout 30 -Retries 3 -IgnoreErrors:$true).Output | Out-Null

		# Step 3: Clean up legacy certgen resources from previous versions
		Write-Log '[Webhook] Cleaning up legacy certgen resources...' -Console:$consoleSwitch
		(Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl delete job clusterip-webhook-certgen-create -n k2s-webhook --ignore-not-found=true' -Timeout 30 -IgnoreErrors:$true).Output | Out-Null
		(Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl delete job clusterip-webhook-certgen-patch -n k2s-webhook --ignore-not-found=true' -Timeout 30 -IgnoreErrors:$true).Output | Out-Null
		(Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl delete secret clusterip-webhook-tls -n k2s-webhook --ignore-not-found=true' -Timeout 30 -IgnoreErrors:$true).Output | Out-Null
		(Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl delete serviceaccount clusterip-webhook-certgen -n k2s-webhook --ignore-not-found=true' -Timeout 30 -IgnoreErrors:$true).Output | Out-Null
		(Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl delete role clusterip-webhook-certgen -n k2s-webhook --ignore-not-found=true' -Timeout 30 -IgnoreErrors:$true).Output | Out-Null
		(Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl delete rolebinding clusterip-webhook-certgen -n k2s-webhook --ignore-not-found=true' -Timeout 30 -IgnoreErrors:$true).Output | Out-Null

		# Step 4: Apply deployment (with init-cert init container)
		Write-Log '[Webhook] Applying deployment and service...' -Console:$consoleSwitch
		$deployResult = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute "kubectl apply -f $remoteDir/deployment.yaml" -Timeout 30 -Retries 3 -IgnoreErrors:$true
		Write-Log ('[Webhook] deployment apply: success={0} output={1}' -f $deployResult.Success, ($deployResult.Output | Out-String).Trim()) -Console:$consoleSwitch

		# Step 5: Trigger rollout restart to regenerate certificate via init container
		Write-Log '[Webhook] Restarting webhook deployment to regenerate certificate...' -Console:$consoleSwitch
		(Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl rollout restart deployment/clusterip-webhook -n k2s-webhook' -Timeout 30 -IgnoreErrors:$true).Output | Out-Null
		$rolloutResult = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl rollout status deployment/clusterip-webhook -n k2s-webhook --timeout=120s' -Timeout 150 -Retries 2 -IgnoreErrors:$true
		if (-not $rolloutResult.Success) {
			Write-Log '[Webhook][Error] Webhook deployment did not become ready after restart' -Console:$consoleSwitch
			return $false
		}

		# Step 6: Validate webhook is operational
		Write-Log '[Webhook] Validating webhook caBundle is set...' -Console:$consoleSwitch
		$caBundleCheck = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute "kubectl get mutatingwebhookconfiguration k2s-webhook -o jsonpath='{.webhooks[0].clientConfig.caBundle}'" -Timeout 30 -IgnoreErrors:$true
		$caBundle = ($caBundleCheck.Output | Out-String).Trim()
		if ([string]::IsNullOrWhiteSpace($caBundle)) {
			Write-Log '[Webhook][Error] MutatingWebhookConfiguration has empty caBundle - webhook will not intercept service creation' -Console:$consoleSwitch
			return $false
		}
		Write-Log '[Webhook] Webhook caBundle validated successfully' -Console:$consoleSwitch

		# Cleanup
		(Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute "rm -rf $remoteDir" -Timeout 30 -IgnoreErrors:$true).Output | Out-Null

		Write-Log '[Webhook] ClusterIP webhook restored successfully' -Console:$consoleSwitch
		return $true
	} catch {
		Write-Log ("[Webhook][Error] Webhook restoration failed: {0}" -f $_.Exception.Message) -Console:$consoleSwitch
		return $false
	}
}

function PerformClusterUpdate {
	<#
	.SYNOPSIS
		Applies a delta package to perform a K2s cluster update.
	.DESCRIPTION
		Implements update flow using a previously extracted delta package.
		This function MUST be executed from the extracted delta package directory, NOT from
		the installed k2s directory. The delta package directory is identified by the presence
		of delta-manifest.json in the current working directory. The delta package directory
		is completed with files from the existing installation and becomes the active K2s
		installation directory recorded in setup.json.
		
		The update handles running clusters automatically:
		- If cluster is running: Applies Debian packages first, then stops cluster, applies Windows artifacts, restarts cluster
		- If cluster is not running: Skips Debian packages, applies Windows artifacts only
		
		High-level phases:
		  1. Load delta-manifest.json
		  2. Detect existing installation folder and target folder
		  3. Version compatibility validation
		  4. Apply Debian package delta, if present and cluster is running
		  5. Stop cluster automatically, if it was running
		  6. Complete the target directory, apply Windows artifacts, switch PATH and InstallFolder
		  7. Clean deprecated Windows kubelet flags
		  8. Restart cluster automatically, if it was running before
		  9. Import container images from image-delta
		  10. Run optional hooks placeholder
		  11. Basic health checks, if cluster is running
		  12. Restore CoreDNS etcd plugin configuration
		  13. Restore ClusterIP webhook TLS certificates
		  14. Update VERSION and setup.json versions
	.PARAMETER ExecuteHooks
		Execute lifecycle hooks (currently placeholder; no hooks executed yet).
	.PARAMETER ShowProgress
		Emit coarse progress via Write-Progress at phase boundaries.
	.PARAMETER ShowLogs
		Mirror logs to console.
	.OUTPUTS
		[bool] success indicator.
	.NOTES
		Keeps offline guarantees (no network pulls).
		IMPORTANT: Execute this function from the extracted delta package directory.
		The user must:
		  1. Extract the delta package zip to the desired final install directory: Expand-Archive k2s-delta-xxx.zip -Destination C:\k2s-new
		  2. Navigate to the extracted directory: cd C:\k2s-new
		  3. Run the update: .\k2s.exe system update
		The cluster will be automatically stopped and restarted if it was running before the update.
	#>
	[CmdletBinding()]
	param(
		[switch] $ExecuteHooks,
		[switch] $ShowProgress,
		[switch] $ShowLogs
	)

	$consoleSwitch = $ShowLogs
	Write-Log '#####################################################################' -Console:$consoleSwitch
	Write-Log '[DeltaUpdate] Delta update starting' -Console:$consoleSwitch
	Write-Log '#####################################################################' -Console:$consoleSwitch
	Write-Log ("[Update] Parameters: ExecuteHooks={0} ShowProgress={1} ShowLogs={2}" -f $ExecuteHooks, $ShowProgress, $ShowLogs) -Console:$consoleSwitch

	# Detect delta root - current directory must contain delta-manifest.json
	$deltaRoot = $PWD.Path
	$manifestPath = Join-Path $deltaRoot 'delta-manifest.json'
	
	if (-not (Test-Path -LiteralPath $manifestPath)) {
		$errorMsg = @"
[Update][Error] delta-manifest.json not found in current directory.

This command must be run from the extracted delta package directory.

Usage:
  1. Extract the delta package: Expand-Archive k2s-delta-xxx.zip -Destination .\delta
  2. Navigate to extracted directory: cd .\delta
  3. Run update: .\k2s.exe system update

Current directory: $deltaRoot
"@
		Write-Log $errorMsg -Console
		return $false
	}
	
	Write-Log ("[Update] Delta package root detected: {0}" -f $deltaRoot) -Console:$consoleSwitch

	# Check if k2s is currently running - we'll handle stopping/starting automatically
	$setupInfo = Get-SetupInfo
	$wasRunning = $false
	if ($setupInfo.Name) {
		$clusterState = Get-RunningState -SetupName $setupInfo.Name
		$wasRunning = ($clusterState.IsRunning -eq $true)
		if ($wasRunning) {
			Write-Log '[Update] K2s is currently running - will stop after applying Debian packages' -Console:$consoleSwitch
		} else {
			Write-Log '[Update] K2s is not running' -Console:$consoleSwitch
		}
	}

	$script:phaseId = 0
	$script:totalPhases = 14
	function _phase { 
		param($name) 
		$script:phaseId++
		if ($ShowProgress) { 
			Write-Progress -Activity 'Cluster delta update' -Id 1 -Status ("{0}/{1}: {2}" -f $script:phaseId, $script:totalPhases, $name) -PercentComplete (($script:phaseId) * 100 / $script:totalPhases) 
		} 
		Write-Log ("[Update] Phase {0}/{1}: {2}" -f $script:phaseId, $script:totalPhases, $name) -Console:$consoleSwitch 
	}

	# 1. Load manifest from delta root
	_phase 'Manifest'
	$manifestRaw = Get-Content -LiteralPath $manifestPath -Raw
	try { $manifest = $manifestRaw | ConvertFrom-Json } catch { Write-Log ("[Update][Error] Manifest parse failed: {0}" -f $_.Exception.Message) -Console; return $false }
	Write-Log ("[Update] Manifest loaded: Added={0} Changed={1} Removed={2}" -f $manifest.AddedCount, $manifest.ChangedCount, $manifest.RemovedCount) -Console:$consoleSwitch

	# 2. Get source and target installation folders
	_phase 'DetectTarget'
	try {
		$oldInstallPath = Get-ClusterInstalledFolder
		$targetInstallPath = $deltaRoot
		Write-Log ("[Update] Existing installation folder: {0}" -f $oldInstallPath) -Console:$consoleSwitch
		Write-Log ("[Update] New target installation folder: {0}" -f $targetInstallPath) -Console:$consoleSwitch
		
		if (-not (Test-Path -LiteralPath $oldInstallPath)) {
			Write-Log ("[Update][Error] Existing installation folder does not exist: {0}" -f $oldInstallPath) -Console
			return $false
		}

		if (([IO.Path]::GetFullPath($oldInstallPath).TrimEnd('\')) -ieq ([IO.Path]::GetFullPath($targetInstallPath).TrimEnd('\'))) {
			Write-Log '[Update][Error] Delta package directory must be different from the existing installation folder.' -Console
			return $false
		}
	} catch {
		Write-Log ("[Update][Error] Failed to determine installation folders: {0}" -f $_.Exception.Message) -Console
		return $false
	}

	# 3. Validate version compatibility
	_phase 'VersionValidation'
	
	# Get the currently installed cluster version from the existing installation folder
	try {
		$currentVersion = Get-ProductVersionGivenKubePath -KubePathLocal $oldInstallPath
		Write-Log ("[Update] Current installed version: {0} (from {1})" -f $currentVersion, $oldInstallPath) -Console:$consoleSwitch
	} catch {
		Write-Log ("[Update][Error] Failed to get current installed version: {0}" -f $_.Exception.Message) -Console
		return $false
	}
	
	$deltaBasePackage = [string]$manifest.BasePackage
	$deltaTargetPackage = [string]$manifest.TargetPackage
	
	# Use version fields directly from manifest (populated from VERSION files during delta generation)
	# Fall back to parsing package name for backward compatibility with older manifests
	function _ExtractVersionFromPackage([string]$packageName) {
		if ([string]::IsNullOrWhiteSpace($packageName)) { return $null }
		# Match patterns like k2s-v1.6.0, k2s-1.6.0, or just 1.6.0
		if ($packageName -match 'k2s-?v?(\d+\.\d+\.\d+)') { return $matches[1] }
		# Fallback: try to find version pattern anywhere in the name
		if ($packageName -match '(\d+\.\d+\.\d+)') { return $matches[1] }
		return $null
	}
	
	# Prefer explicit version fields from manifest; fall back to filename parsing for older manifests
	$deltaBaseVersion = if (-not [string]::IsNullOrWhiteSpace($manifest.BaseVersion)) { 
		$manifest.BaseVersion.Trim() 
	} else { 
		_ExtractVersionFromPackage $deltaBasePackage 
	}
	$deltaTargetVersion = if (-not [string]::IsNullOrWhiteSpace($manifest.TargetVersion)) { 
		$manifest.TargetVersion.Trim() 
	} else { 
		_ExtractVersionFromPackage $deltaTargetPackage 
	}
	
	Write-Log ("[Update] Version Check: Current={0}, DeltaBase={1}, DeltaTarget={2}" -f $currentVersion, $deltaBaseVersion, $deltaTargetVersion) -Console:$consoleSwitch
	
	# Validate that current system version matches delta base version
	if ($deltaBaseVersion -and $currentVersion -ne $deltaBaseVersion) {
		$errorMsg = "[Update][Error] Version mismatch: Current system version '{0}' does not match delta base version '{1}'. Delta package '{2}' cannot be applied to this system." -f $currentVersion, $deltaBaseVersion, $deltaBasePackage
		Write-Log $errorMsg -Console
		return $false
	}
	
	if (-not $deltaBaseVersion) {
		Write-Log ("[Update][Warn] Could not extract base version from package name '{0}'. Proceeding without version validation." -f $deltaBasePackage) -Console:$consoleSwitch
	} else {
		Write-Log ("[Update] Version validation passed: Delta base version '{0}' matches current system version '{1}'" -f $deltaBaseVersion, $currentVersion) -Console:$consoleSwitch
	}
	
	if ($deltaTargetVersion) {
		Write-Log ("[Update] Target version after update: {0}" -f $deltaTargetVersion) -Console:$consoleSwitch
	}

	# 4. Debian package delta (apply while cluster is running if needed)
	_phase 'DebianPackages'
	$targetKubernetesVersion = $null
	if ($manifest.DebianDeltaRelativePath) {
		$debDir = Join-Path $deltaRoot $manifest.DebianDeltaRelativePath
		$targetKubernetesVersion = Get-TargetKubernetesVersionFromDebianDelta -DebianDeltaPath $debDir
		if ($targetKubernetesVersion) {
			Write-Log ("[Update] Target Kubernetes version from Debian delta: {0}" -f $targetKubernetesVersion) -Console:$consoleSwitch
		}
		$applyScript = Join-Path $debDir 'apply-debian-delta.sh'
		if (Test-Path -LiteralPath $applyScript) {
			if ($wasRunning) {
				Write-Log '[Update] Applying Debian delta while cluster is running...' -Console:$consoleSwitch
				try {
					# Direct invocation; module now provides Invoke-CommandInMasterVM
					Invoke-CommandInMasterVM -ScriptPath $applyScript -WorkingDirectory $debDir -ShowLogs:$ShowLogs
					Write-Log '[Update] Debian delta applied successfully.' -Console:$consoleSwitch
				} catch { 
					Write-Log ("[Update][Error] Debian delta execution failed: {0}" -f $_.Exception.Message) -Console
					throw
				}
			} else {
				Write-Log '[Update][Warn] Cluster not running - cannot apply Debian delta. Will skip Debian updates.' -Console:$consoleSwitch
			}
		} else {
			Write-Log '[Update][Info] No Debian delta apply script found; skipping' -Console:$consoleSwitch
		}
	} else { Write-Log '[Update] No Debian delta in manifest' -Console:$consoleSwitch }

	# 5. Stop cluster if it was running
	_phase 'StopCluster'
	if ($wasRunning) {
		Write-Log '[Update] Stopping K2s cluster to apply Windows artifacts...' -Console
		try {
			if (Get-Command -Name Stop-ClusterNode -ErrorAction SilentlyContinue) {
				Stop-ClusterNode -SetupName $setupInfo.Name -ShowLogs:$ShowLogs
				Write-Log '[Update] K2s cluster stopped successfully.' -Console:$consoleSwitch
			} else {
				Write-Log '[Update][Warn] Stop-ClusterNode not available; attempting k2s.exe stop from existing installation...' -Console:$consoleSwitch
				$k2sExe = Join-Path $oldInstallPath 'k2s.exe'
				if (Test-Path -LiteralPath $k2sExe) {
					& $k2sExe stop
					if ($LASTEXITCODE -ne 0) { throw "k2s.exe stop returned exit code $LASTEXITCODE" }
					Write-Log '[Update] K2s cluster stopped successfully.' -Console:$consoleSwitch
				} else {
					throw "k2s.exe not found at $k2sExe"
				}
			}
		} catch {
			Write-Log ("[Update][Error] Failed to stop K2s cluster: {0}" -f $_.Exception.Message) -Console
			throw
		}
	} else {
		Write-Log '[Update] Cluster was not running; skipping stop phase.' -Console:$consoleSwitch
	}

	# 6. Apply Windows artifacts (Added + Changed) from delta root to target install path
	_phase 'WindowsArtifacts'
	Write-Log ("[Update] Completing target installation at '{0}' using existing installation '{1}'" -f $targetInstallPath, $oldInstallPath) -Console:$consoleSwitch

	# Safety check: Define cluster-specific files that must keep the values from the existing installation.
	# These files are generated during kubeadm init and contain cluster-specific certificates and configuration.
	$clusterConfigProtectedFiles = @(
		'config'  # Main kubeconfig at $kubePath\config
	)
	$clusterConfigProtectedPaths = @(
		'etc/kubernetes/bootstrap-kubelet.conf',
		'etc/kubernetes/pki/*',
		'var/lib/kubelet/config.yaml',
		'var/lib/kubelet/pki/*'
	)
	
	# Helper function to check if a path should be protected
	function Test-ProtectedClusterFile {
		param([string]$RelPath)
		$normalizedPath = $RelPath -replace '\\', '/'
		$leaf = [IO.Path]::GetFileName($normalizedPath)
		
		# Check exact filename matches
		foreach ($f in $clusterConfigProtectedFiles) {
			if ($leaf -ieq $f) { return $true }
		}
		
		# Check path patterns
		foreach ($pattern in $clusterConfigProtectedPaths) {
			$normalizedPattern = $pattern -replace '\\', '/'
			if ($normalizedPath -like $normalizedPattern) { return $true }
		}
		return $false
	}

	function Test-PathInManifestList {
		param(
			[string] $RelPath,
			[object[]] $ManifestPaths,
			[switch] $AsDirectory
		)

		$normalizedPath = ($RelPath -replace '\\', '/').TrimStart('/')
		foreach ($entry in @($ManifestPaths)) {
			if ([string]::IsNullOrWhiteSpace($entry)) { continue }
			$normalizedEntry = ([string]$entry -replace '\\', '/').TrimStart('/').TrimEnd('/')
			if ($AsDirectory) {
				if (($normalizedPath -ieq $normalizedEntry) -or $normalizedPath.StartsWith("$normalizedEntry/", [StringComparison]::OrdinalIgnoreCase)) { return $true }
			} elseif ($normalizedPath -ieq $normalizedEntry) {
				return $true
			}
		}

		return $false
	}

	function Copy-MissingFilesFromOldInstall {
		param(
			[string] $SourceRoot,
			[string] $DestinationRoot,
			[object] $Manifest
		)

		$sourceRootFull = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
		$removedManifestFiles = @($Manifest.Removed) | Where-Object { $_ -and ($_ -ne '') }
		$wholesaleManifestDirs = @($Manifest.WholeDirectories) | Where-Object { $_ -and ($_ -ne '') }
		$copiedCount = 0
		$protectedRestoredCount = 0
		$skippedRemovedCount = 0
		$skippedWholesaleCount = 0
		$skippedExistingCount = 0

		foreach ($sourceFile in (Get-ChildItem -LiteralPath $sourceRootFull -Recurse -File)) {
			$rel = $sourceFile.FullName.Substring($sourceRootFull.Length) -replace '^[\\/]+', '' -replace '\\', '/'
			$dest = Join-Path $DestinationRoot $rel
			$shouldRestoreProtected = Test-ProtectedClusterFile -RelPath $rel

			if (Test-PathInManifestList -RelPath $rel -ManifestPaths $removedManifestFiles) {
				$skippedRemovedCount++
				continue
			}

			if ((Test-PathInManifestList -RelPath $rel -ManifestPaths $wholesaleManifestDirs -AsDirectory) -and -not $shouldRestoreProtected) {
				$skippedWholesaleCount++
				continue
			}

			if ((Test-Path -LiteralPath $dest) -and -not $shouldRestoreProtected) {
				$skippedExistingCount++
				continue
			}

			$destDir = Split-Path $dest -Parent
			if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }

			Copy-Item -LiteralPath $sourceFile.FullName -Destination $dest -Force
			if ($shouldRestoreProtected) { $protectedRestoredCount++ } else { $copiedCount++ }
		}

		Write-Log ("[Update] Completed target installation from existing install: copied={0}, restoredProtected={1}, skippedExisting={2}, skippedRemoved={3}, skippedWholesale={4}" -f $copiedCount, $protectedRestoredCount, $skippedExistingCount, $skippedRemovedCount, $skippedWholesaleCount) -Console:$consoleSwitch
	}

	Copy-MissingFilesFromOldInstall -SourceRoot $oldInstallPath -DestinationRoot $targetInstallPath -Manifest $manifest
	
	# 6a. Apply wholesale directories first - these are replaced entirely (e.g., bin/kube, bin/docker)
	# Wholesale directories contain binaries that must be completely replaced, not merged
	$wholesaleDirs = @($manifest.WholeDirectories) | Where-Object { $_ -and ($_ -ne '') }
	if ($wholesaleDirs.Count -gt 0) {
		# Stop Windows services whose executables reside inside wholesale directories.
		# Even when the cluster is not running (flanneld/kubelet/kubeproxy are down),
		# containerd or other services may still be active and lock their binaries,
		# causing sporadic "Access is denied" / "being used by another process" errors.
		$servicesToDirMap = @{
			'containerd' = 'bin/containerd'
			'docker'     = 'bin/docker'
		}
		$stoppedServices = @()
		foreach ($svcName in $servicesToDirMap.Keys) {
			$svcDir = $servicesToDirMap[$svcName] -replace '/', '\'
			$matchesWholesale = $wholesaleDirs | Where-Object { ($_ -replace '/', '\') -ieq $svcDir }
			if (-not $matchesWholesale) { continue }

			$svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
			if ($svc -and $svc.Status -ne 'Stopped') {
				Write-Log ("[Update] Stopping service '{0}' (status: {1}) to unlock files in wholesale directory '{2}'" -f $svcName, $svc.Status, $svcDir) -Console:$consoleSwitch
				try {
					Stop-Service -Name $svcName -Force -ErrorAction Stop
					# Wait briefly for the process to fully release file handles
					Start-Sleep -Seconds 2
					$stoppedServices += $svcName
					Write-Log ("[Update] Service '{0}' stopped successfully" -f $svcName) -Console:$consoleSwitch
				} catch {
					Write-Log ("[Update][Warn] Could not stop service '{0}': {1}" -f $svcName, $_.Exception.Message) -Console:$consoleSwitch
				}
			}
		}
		# Also stop any leftover containerd-shim processes that may hold handles
		Stop-Process -Name 'containerd-shim-runhcs-v1' -Force -ErrorAction SilentlyContinue
		Stop-Process -Name 'containerd' -Force -ErrorAction SilentlyContinue

		Write-Log ("[Update] Applying {0} wholesale directories" -f $wholesaleDirs.Count) -Console:$consoleSwitch
		foreach ($wd in $wholesaleDirs) {
			$srcDir = Join-Path $deltaRoot $wd
			if (-not (Test-Path -LiteralPath $srcDir)) {
				Write-Log ("[Update][Warn] Wholesale directory not found in delta: {0}" -f $wd) -Console:$consoleSwitch
				continue
			}
			$dstDir = Join-Path $targetInstallPath $wd

			if (([IO.Path]::GetFullPath($srcDir).TrimEnd('\')) -ieq ([IO.Path]::GetFullPath($dstDir).TrimEnd('\'))) {
				Write-Log ("[Update] Wholesale directory already staged in target: {0}" -f $wd) -Console:$consoleSwitch
				continue
			}
			
			# Remove existing directory completely for clean replacement.
			# Retry with back-off in case file handles are still being released.
			if (Test-Path -LiteralPath $dstDir) {
				Write-Log ("[Update] Removing existing directory for replacement: {0}" -f $wd) -Console:$consoleSwitch
				$maxRetries = 5
				$retryDelay = 2
				$removed = $false
				for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
					try {
						Remove-Item -LiteralPath $dstDir -Recurse -Force -ErrorAction Stop
						$removed = $true
						break
					} catch {
						if ($attempt -lt $maxRetries) {
							Write-Log ("[Update][Warn] Attempt {0}/{1} to remove '{2}' failed: {3} - retrying in {4}s" -f $attempt, $maxRetries, $wd, $_.Exception.Message, $retryDelay) -Console:$consoleSwitch
							Start-Sleep -Seconds $retryDelay
							$retryDelay = [Math]::Min($retryDelay * 2, 10)
						} else {
							Write-Log ("[Update][Error] Failed to remove directory '{0}' after {1} attempts: {2}" -f $wd, $maxRetries, $_.Exception.Message) -Console
						}
					}
				}
				if (-not $removed) {
					Write-Log ("[Update][Warn] Continuing despite failure to fully remove '{0}' - copy will attempt force-overwrite" -f $wd) -Console:$consoleSwitch
				}
			}
			
			# Create parent directory if needed and copy wholesale directory
			$dstParent = Split-Path $dstDir -Parent
			if (-not (Test-Path -LiteralPath $dstParent)) {
				New-Item -ItemType Directory -Path $dstParent -Force | Out-Null
			}
			
			try {
				# Copy the entire directory (not contents) since we removed the target
				Copy-Item -LiteralPath $srcDir -Destination $dstDir -Recurse -Force
				Write-Log ("[Update] Replaced wholesale directory: {0}" -f $wd) -Console:$consoleSwitch
			} catch {
				Write-Log ("[Update][Error] Failed to copy wholesale directory '{0}': {1}" -f $wd, $_.Exception.Message) -Console
			}
		}
	} else {
		Write-Log '[Update] No wholesale directories to apply' -Console:$consoleSwitch
	}
	
	$addedFiles   = @($manifest.Added)
	$changedFiles = @($manifest.Changed)
	$filesToApply = @($addedFiles + $changedFiles) | Where-Object { $_ -and ($_ -ne '') }
	$appliedCount = 0
	$skippedCount = 0
	
	foreach ($rel in $filesToApply) {
		# Safety check: Never overwrite cluster-specific configuration files
		if (Test-ProtectedClusterFile -RelPath $rel) {
			Write-Log ("[Update][Skip] Protected cluster config file skipped: {0}" -f $rel) -Console:$consoleSwitch
			$skippedCount++
			continue
		}
		
		$src = Join-Path $deltaRoot $rel
		if (-not (Test-Path -LiteralPath $src)) { Write-Log ("[Update][Warn] Source missing in delta: {0}" -f $rel) -Console:$consoleSwitch; continue }
		$dest = Join-Path $targetInstallPath $rel
		if (([IO.Path]::GetFullPath($src)) -ieq ([IO.Path]::GetFullPath($dest))) {
			Write-Log ("[Update] Already staged: {0}" -f $rel) -Console:$consoleSwitch
			$appliedCount++
			continue
		}
		$destDir = Split-Path $dest -Parent
		if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
		
		try { 
			Copy-Item -LiteralPath $src -Destination $dest -Force 
			Write-Log ("[Update] Applied: {0}" -f $rel) -Console:$consoleSwitch
			$appliedCount++
		} catch { 
			Write-Log ("[Update][Error] Copy failed '{0}' -> '{1}': {2}" -f $src, $dest, $_.Exception.Message) -Console 
		}
	}
	Write-Log ("[Update] Applied {0} Windows artifacts (skipped {1} protected cluster config files)" -f $appliedCount, $skippedCount) -Console:$consoleSwitch

	# Switch the installation folder after the new target has the files required by target-path helpers.
	try {
		Write-Log ("[Update] Updating machine PATH from '{0}' to '{1}'" -f $oldInstallPath, $targetInstallPath) -Console:$consoleSwitch
		Set-K2sMachinePathEntries -OldKubePath $oldInstallPath -NewKubePath $targetInstallPath -ShowLogs:$ShowLogs
		Write-Log ("[Update] Updating setup.json install folder from '{0}' to '{1}'" -f $oldInstallPath, $targetInstallPath) -Console:$consoleSwitch
		Set-ConfigInstallFolder -Value $targetInstallPath
		Write-Log '[Update] Machine PATH and setup configuration install folder updated successfully' -Console:$consoleSwitch
	} catch {
		Write-Log ("[Update][Error] Failed to update active installation path: {0}" -f $_.Exception.Message) -Console
		throw
	}

	# 6b. Regenerate containerd config.toml from updated template if the template changed.
	# The live config.toml is generated at install time from config.toml.template by replacing
	# %BEST-DRIVE%, %INSTALLATION_DIRECTORY%, and %CONTAINERD_TOKEN% placeholders.
	# The template is diffed and staged in the delta package, but the generated config.toml
	# does not exist in packages, so it must be regenerated after the template is updated.
	# Without this, containerd keeps using the old sandbox_image (pause-win) version.
	$containerdTemplatePath = 'cfg/containerd/config.toml.template'
	$templateWasUpdated = $filesToApply | Where-Object { ($_ -replace '\\', '/') -ieq $containerdTemplatePath }
	if ($templateWasUpdated) {
		Write-Log '[Update] Containerd config.toml.template was updated - regenerating config.toml...' -Console:$consoleSwitch
		$containerdTomlPath = Join-Path $targetInstallPath 'cfg\containerd\config.toml'
		try {
			# Import the containerd module from the target installation so that Get-KubePath
			# (resolved via PSScriptRoot) points to the correct install directory and all
			# dependent modules (system, config, path) are loaded from the same tree.
			$containerdModule = Join-Path $targetInstallPath 'lib\modules\k2s\k2s.node.module\windowsnode\downloader\artifacts\containerd\containerd.module.psm1'
			if (-not (Test-Path -LiteralPath $containerdModule)) {
				throw "Containerd module not found at $containerdModule"
			}
			Import-Module $containerdModule -Force

			# 1. Generate config.toml from template (replaces %BEST-DRIVE%)
			Set-RootPathForImagesInConfig $containerdTomlPath
			# 2. Replace %INSTALLATION_DIRECTORY% with escaped kubePath
			Set-InstallationDirectory $containerdTomlPath
			# 3. Replace %CONTAINERD_TOKEN% with registry auth token
			Set-UserTokenForRegistryInConfig $containerdTomlPath

			if (Test-Path -LiteralPath $containerdTomlPath) {
				Write-Log "[Update] Containerd config.toml regenerated successfully at $containerdTomlPath" -Console:$consoleSwitch
			} else {
				throw "config.toml was not created at $containerdTomlPath after template substitution"
			}
		} catch {
			Write-Log ("[Update][Error] Failed to regenerate containerd config.toml: {0}" -f $_.Exception.Message) -Console
			throw
		}
	} else {
		Write-Log '[Update] Containerd config.toml.template not changed - skipping config.toml regeneration' -Console:$consoleSwitch
	}

	# 6c. Remove obsolete files (Removed) from target installation
	$removedFiles = @($manifest.Removed) | Where-Object { $_ -and ($_ -ne '') }
	if ($removedFiles.Count -gt 0) {
		Write-Log ("[Update] Removing {0} obsolete files from target installation" -f $removedFiles.Count) -Console:$consoleSwitch
		$removedCount = 0
		foreach ($rel in $removedFiles) {
			$target = Join-Path $targetInstallPath $rel
			if (Test-Path -LiteralPath $target) {
				try {
					Remove-Item -LiteralPath $target -Force
					Write-Log ("[Update] Removed: {0}" -f $rel) -Console:$consoleSwitch
					$removedCount++
				} catch {
					Write-Log ("[Update][Warn] Failed to remove '{0}': {1}" -f $rel, $_.Exception.Message) -Console:$consoleSwitch
				}
			} else {
				Write-Log ("[Update][Info] Already absent: {0}" -f $rel) -Console:$consoleSwitch
			}
		}
		Write-Log ("[Update] Removed {0} of {1} obsolete files" -f $removedCount, $removedFiles.Count) -Console:$consoleSwitch
	} else {
		Write-Log '[Update] No files to remove' -Console:$consoleSwitch
	}

	# 6d. Clean deprecated kubelet flags from Windows kubeadm-flags.env
	# The --pod-infra-container-image flag was deprecated in K8s 1.27 and removed in 1.34
	# This matches the Linux fix in apply-debian-delta.sh
	_phase 'CleanKubeletFlags'
	$kubeletFlagsFile = "$($env:SystemDrive)\var\lib\kubelet\kubeadm-flags.env"
	if (Test-Path -LiteralPath $kubeletFlagsFile) {
		Write-Log "[Update] Cleaning deprecated kubelet flags from $kubeletFlagsFile" -Console:$consoleSwitch
		try {
			$content = Get-Content -LiteralPath $kubeletFlagsFile -Raw
			$originalContent = $content
			
			# Remove --pod-infra-container-image flag (deprecated in 1.27, removed in 1.34)
			$content = $content -replace '--pod-infra-container-image=[^\s"]*\s*', ''
			
			# Clean up any double spaces left behind
			$content = $content -replace '\s+', ' '
			$content = $content -replace '"\s+"', '""'
			
			if ($content -ne $originalContent) {
				Set-Content -LiteralPath $kubeletFlagsFile -Value $content.Trim() -NoNewline
				Write-Log "[Update] Removed deprecated --pod-infra-container-image flag" -Console:$consoleSwitch
				Write-Log "[Update] Kubelet flags after cleanup: $($content.Trim())" -Console:$consoleSwitch
			} else {
				Write-Log "[Update] No deprecated kubelet flags to remove" -Console:$consoleSwitch
			}
		} catch {
			Write-Log ("[Update][Warn] Failed to clean kubelet flags: {0}" -f $_.Exception.Message) -Console:$consoleSwitch
		}
	} else {
		Write-Log "[Update] Kubelet flags file not found at $kubeletFlagsFile (may be normal for some setups)" -Console:$consoleSwitch
	}

	# 7. Restart cluster if it was running before
	_phase 'RestartCluster'
	if ($wasRunning) {
		Write-Log '[Update] Restarting K2s cluster...' -Console
		try {
			$k2sExe = Join-Path $targetInstallPath 'k2s.exe'
			if (Test-Path -LiteralPath $k2sExe) {
				$argsCall = @('start')
				if ($ShowLogs) { $argsCall += '-o' }
				& $k2sExe @argsCall
				if ($LASTEXITCODE -ne 0) { throw "k2s.exe start returned exit code $LASTEXITCODE" }
				Write-Log '[Update] K2s cluster restarted successfully.' -Console:$consoleSwitch
			} else {
				throw "k2s.exe not found at $k2sExe"
			}
		} catch {
			Write-Log ("[Update][Error] Failed to restart K2s cluster: {0}" -f $_.Exception.Message) -Console
			Write-Log '[Update][Error] You may need to manually start the cluster: k2s start' -Console
			throw
		}
	} else {
		Write-Log '[Update] Cluster was not running before update; not restarting.' -Console:$consoleSwitch
	}

	# 8. Import container images from delta package.
	#    Delta packaging stages images into image-delta/windows/images/*.tar and image-delta/linux/images/*.tar.
	#    Linux images may already have been imported by Phase 4 (Invoke-CommandInMasterVM → apply-debian-delta.sh
	#    → buildah pull). Phase 8 re-imports them as a safety net and also covers the case where
	#    Phase 4 was skipped because the cluster was not running at the time.
	#    Windows images use ctr to import into the containerd k8s.io namespace — the same pattern used by
	#    Invoke-DeployWindowsImages in downloader.module.psm1 and ImportImage.ps1.
	_phase 'ContainerImages'

	# --- 8a. Windows images ---
	# Collect Windows image tar files: primary path from delta packaging, then fallback
	$windowsImagesDirs = @(
		(Join-Path $deltaRoot 'image-delta\windows\images'),
		(Join-Path $deltaRoot 'images')
	)
	$winImageFiles = @()
	foreach ($winImgDir in $windowsImagesDirs) {
		if ((Test-Path -LiteralPath $winImgDir) -and $winImageFiles.Count -eq 0) {
			$found = Get-ChildItem -LiteralPath $winImgDir -File -Filter '*.tar' -ErrorAction SilentlyContinue
			if ($found -and $found.Count -gt 0) {
				$winImageFiles = @($found)
				Write-Log ("[Update] Found {0} Windows image archives in {1}" -f $winImageFiles.Count, $winImgDir) -Console:$consoleSwitch
			}
		}
	}
	if ($winImageFiles.Count -gt 0) {
		# Resolve ctr from the target installation (containerd must be running after Phase 7 restart)
		$ctrExe = Join-Path $targetInstallPath 'bin\containerd\ctr.exe'
		if (-not (Test-Path -LiteralPath $ctrExe)) {
			Write-Log ("[Update][Warn] ctr.exe not found at {0}; cannot import Windows images" -f $ctrExe) -Console:$consoleSwitch
		} else {
			Write-Log ("[Update] Loading {0} Windows container image archives via ctr" -f $winImageFiles.Count) -Console:$consoleSwitch
			$imageLoadedCount = 0
			foreach ($img in $winImageFiles) {
				Write-Log ("[Update] Loading Windows image: {0}" -f $img.Name) -Console:$consoleSwitch
				$maxRetries = 3
				$retryDelay = 2
				$success = $false
				for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
					try {
						$importSuccess = Invoke-Ctr -Arguments '-n', 'k8s.io', 'images', 'import', $img.FullName -CtrExePath $ctrExe
						if ($importSuccess) {
							$success = $true
							break
						}
						if ($attempt -lt $maxRetries) {
							Write-Log ("[Update]   Attempt {0} failed (exit code {1}), retrying after {2}s..." -f $attempt, $LASTEXITCODE, $retryDelay) -Console:$consoleSwitch
							Start-Sleep -Seconds $retryDelay
						}
					} catch {
						if ($attempt -lt $maxRetries) {
							Write-Log ("[Update]   Attempt {0} error: {1}, retrying after {2}s..." -f $attempt, $_.Exception.Message, $retryDelay) -Console:$consoleSwitch
							Start-Sleep -Seconds $retryDelay
						}
					}
				}
				if ($success) {
					$imageLoadedCount++
					Write-Log ("[Update] Image loaded successfully: {0}" -f $img.Name) -Console:$consoleSwitch
				} else {
					Write-Log ("[Update][Warn] Failed to load image after {0} attempts: {1}" -f $maxRetries, $img.Name) -Console:$consoleSwitch
				}
			}
			Write-Log ("[Update] Loaded {0} of {1} Windows container images" -f $imageLoadedCount, $winImageFiles.Count) -Console:$consoleSwitch
		}
	} else {
		Write-Log '[Update] No Windows image archives found in delta package; skipping Windows image load' -Console:$consoleSwitch
	}

	# --- 8b. Linux images ---
	# Import Linux images into the control-plane VM via SCP + buildah.
	# Phase 4 (DebianPackages) imports these as part of apply-debian-delta.sh when the cluster was running.
	# This step acts as a safety net and also covers the scenario where the cluster was not running during Phase 4.
	$linuxImagesDir = Join-Path $deltaRoot 'image-delta\linux\images'
	if (Test-Path -LiteralPath $linuxImagesDir) {
		$linuxTarFiles = Get-ChildItem -LiteralPath $linuxImagesDir -File -Filter '*.tar' -ErrorAction SilentlyContinue
		if ($linuxTarFiles -and $linuxTarFiles.Count -gt 0) {
			if ($wasRunning) {
				# Cluster is running (restarted in Phase 7) — VM is reachable via SSH
				if (Get-Command -Name Invoke-CmdOnControlPlaneViaSSHKey -ErrorAction SilentlyContinue) {
					Write-Log ("[Update] Importing {0} Linux container images into control-plane VM" -f $linuxTarFiles.Count) -Console:$consoleSwitch
					try {
						$remoteImgDir = '/tmp/k2s-delta-images'
						(Invoke-CmdOnControlPlaneViaSSHKey "sudo mkdir -p $remoteImgDir && sudo chown `$(whoami) $remoteImgDir" -Retries 2 -Timeout 2).Output | Out-Null
						Copy-ToControlPlaneViaSSHKey -Source $linuxImagesDir -Target $remoteImgDir -IgnoreErrors:$false
						$linuxLoadedCount = 0
						foreach ($ltar in $linuxTarFiles) {
							$remoteTar = "$remoteImgDir/images/$($ltar.Name)"
							Write-Log ("[Update] Loading Linux image: {0}" -f $ltar.Name) -Console:$consoleSwitch
							$importResult = Invoke-CmdOnControlPlaneViaSSHKey "sudo buildah pull oci-archive:$remoteTar 2>&1" -Retries 2 -Timeout 120
							if ($importResult.Output -notmatch 'error') {
								$linuxLoadedCount++
								Write-Log ("[Update] Linux image loaded successfully: {0}" -f $ltar.Name) -Console:$consoleSwitch
							} else {
								Write-Log ("[Update][Warn] Linux image import may have failed for {0}: {1}" -f $ltar.Name, $importResult.Output) -Console:$consoleSwitch
							}
						}
						# Clean up temporary images directory
						(Invoke-CmdOnControlPlaneViaSSHKey "sudo rm -rf $remoteImgDir" -Retries 1 -Timeout 2 -IgnoreErrors:$true).Output | Out-Null
						Write-Log ("[Update] Loaded {0} of {1} Linux container images" -f $linuxLoadedCount, $linuxTarFiles.Count) -Console:$consoleSwitch
					} catch {
						Write-Log ("[Update][Warn] Failed to import Linux images: {0}" -f $_.Exception.Message) -Console:$consoleSwitch
					}
				} else {
					Write-Log '[Update][Warn] SSH helper not available; cannot import Linux images into VM' -Console:$consoleSwitch
				}
			} else {
				Write-Log ("[Update][Warn] Cluster not running; {0} Linux images in delta package will need to be imported after cluster start" -f $linuxTarFiles.Count) -Console:$consoleSwitch
			}
		}
	} else {
		Write-Log '[Update] No Linux image archives found in delta package; skipping Linux image load' -Console:$consoleSwitch
	}

	# 9. Hooks placeholder
	_phase 'Hooks'
	if ($ExecuteHooks) { Write-Log '[Update][Info] Hooks execution placeholder (none implemented).' -Console:$consoleSwitch } else { Write-Log '[Update] Hooks disabled.' -Console:$consoleSwitch }

	# 10. Health check
	_phase 'Health'
	try {
		if ($wasRunning) {
			Write-Log '[Update] Performing health check on restarted cluster...' -Console:$consoleSwitch
			if (Get-Command -Name Wait-ForAPIServer -ErrorAction SilentlyContinue) { Wait-ForAPIServer -TimeoutSeconds 60 }
			if (Get-Command -Name Get-NodeReadySummary -ErrorAction SilentlyContinue) { $summary = Get-NodeReadySummary; Write-Log ("[Update] Node readiness: {0}" -f $summary) -Console:$consoleSwitch }
		} else {
			Write-Log '[Update] Skipping health check (cluster not running)' -Console:$consoleSwitch
		}
	} catch { Write-Log ("[Update][Warn] Health check encountered issues: {0}" -f $_.Exception.Message) -Console:$consoleSwitch }

	# 11. Restore CoreDNS configuration (kubeadm upgrade may reset customizations)
	_phase 'CoreDnsRestore'
	if ($wasRunning) {
		# Get control plane IP from setup info
		$controlPlaneIp = $null
		if ($setupInfo -and $setupInfo.ControlPlaneNodeHostname) {
			$controlPlaneIp = (Get-ConfiguredIPControlPlane)
		}
		if (-not $controlPlaneIp) {
			$controlPlaneIp = '172.19.1.100'  # Default K2s control plane IP
		}
		
		$coreDnsResult = Restore-CoreDnsEtcdConfiguration -ControlPlaneIp $controlPlaneIp -ShowLogs:$ShowLogs
		if (-not $coreDnsResult) {
			Write-Log '[Update][Warn] CoreDNS restoration may have encountered issues' -Console:$consoleSwitch
		}
	} else {
		Write-Log '[Update] Skipping CoreDNS restoration (cluster not running)' -Console:$consoleSwitch
	}

	# 12. Restore ClusterIP webhook (kubeadm upgrade may invalidate TLS certs/caBundle)
	_phase 'WebhookRestore'
	if ($wasRunning) {
		$webhookResult = Restore-ClusterIPWebhook -TargetInstallPath $targetInstallPath -ShowLogs:$ShowLogs
		if (-not $webhookResult) {
			throw '[Update] ClusterIP webhook restoration failed - services created after this point may get incorrect ClusterIPs. Aborting upgrade.'
		}
	} else {
		Write-Log '[Update] Skipping webhook restoration (cluster not running)' -Console:$consoleSwitch
	}

	# 14. Update VERSION file to reflect successful delta update
	_phase 'UpdateVersion'
	if ($deltaTargetVersion) {
		try {
			# Update VERSION file in the target installation
			$versionFile = Join-Path $targetInstallPath 'VERSION'
			
			if (Test-Path -LiteralPath $versionFile) {
				Write-Log ("[Update] Updating VERSION file from {0} to {1}" -f $currentVersion, $deltaTargetVersion) -Console:$consoleSwitch
				$deltaTargetVersion | Out-File -FilePath $versionFile -Encoding ASCII -Force -NoNewline
				Write-Log ("[Update] VERSION file updated successfully: {0}" -f $versionFile) -Console:$consoleSwitch
			} else {
				Write-Log ("[Update][Warn] VERSION file not found at expected location: {0}" -f $versionFile) -Console:$consoleSwitch
			}
			
			# Update setup.json configuration to reflect the new version.
			# InstallFolder was already switched after the target installation was completed.
			Write-Log ("[Update] Updating setup.json product version from {0} to {1}" -f $currentVersion, $deltaTargetVersion) -Console:$consoleSwitch
			Set-ConfigProductVersion -Value $deltaTargetVersion
			if ($targetKubernetesVersion) {
				Write-Log ("[Update] Updating setup.json Kubernetes version to {0}" -f $targetKubernetesVersion) -Console:$consoleSwitch
				Set-ConfigInstalledKubernetesVersion -Value $targetKubernetesVersion
			} else {
				Write-Log '[Update][Info] Target Kubernetes version not determined; setup.json KubernetesVersion not updated' -Console:$consoleSwitch
			}
			Write-Log '[Update] Setup configuration updated successfully' -Console:$consoleSwitch
		} catch {
			Write-Log ("[Update][Warn] Failed to update version information: {0}" -f $_.Exception.Message) -Console:$consoleSwitch
		}
	} else {
		Write-Log '[Update][Info] Target version not determined; version information not updated' -Console:$consoleSwitch
	}

	Write-Log '[Update] Delta update complete.' -Console:$consoleSwitch
	Write-Log ("Upgraded successfully to K2s version: {0} (active installation: {1})" -f $deltaTargetVersion, $targetInstallPath) -Console:$consoleSwitch
	Write-Log ("[Update] Previous installation remains unchanged at: {0}" -f $oldInstallPath) -Console:$consoleSwitch
	Write-Log '[Update] Keep this directory; it is now the active K2s installation.' -Console:$consoleSwitch
	Write-Log '[Update] Machine PATH was updated. Run refreshenv or open a new terminal so this shell resolves the active installation.' -Console:$consoleSwitch

	if ($ShowProgress) { Write-Progress -Activity 'Cluster delta update' -Id 1 -Completed }
	
	return $true
}

Export-ModuleMember -Function PerformClusterUpdate
Export-ModuleMember -Function Restore-CoreDnsEtcdConfiguration
Export-ModuleMember -Function Restore-ClusterIPWebhook

# region: VM execution helper (Debian delta application)
function Invoke-CommandInMasterVM {
	<#
	.SYNOPSIS
		Copies a host-staged script into the running Hyper-V control plane VM (kubemaster) and executes it.
	.DESCRIPTION
		Reuses existing SSH/key infrastructure exposed by linuxnode vm module (Invoke-CmdOnControlPlaneViaSSHKey,
		Copy-ToControlPlaneViaSSHKey). Assumes Hyper-V (not WSL) environment. Designed primarily for applying the
		Debian delta script generated in a delta package. Provides timing, optional log streaming, and structured
		result object.
	.PARAMETER ScriptPath
		Absolute path on the Windows host to the script to execute (e.g. apply-debian-delta.sh).
	.PARAMETER WorkingDirectory
		Optional host directory containing related assets; copied recursively if provided (only the script is
		required). Defaults to the script's parent directory. Directory contents are placed under /tmp/k2s-delta-deb.
	.PARAMETER ShowLogs
		If set, echo remote stdout/stderr lines (underlying helpers already log; we add phase headers).
	.PARAMETER TimeoutSeconds
		Overall timeout for the remote execution attempt. Does not forcibly kill remote process beyond plink exit.
	.PARAMETER RetryCount
		Number of SSH retries for transient failures (mapped to existing helper retry semantics).
	.PARAMETER NoThrow
		Return result object even if exit code != 0 (caller handles).
	.OUTPUTS
		PSCustomObject { ExitCode; DurationSeconds; RemotePath; Success; }
	.NOTES
		May evolve to include cleanup logic or hash verification of script.
	#>
	[CmdletBinding()] param(
		[Parameter(Mandatory=$true)][string] $ScriptPath,
		[string] $WorkingDirectory = '',
		[switch] $ShowLogs,
		[int] $TimeoutSeconds = 900,
		[int] $RetryCount = 0,
		[switch] $NoThrow
	)

	$consoleSwitch = $ShowLogs
	if ([string]::IsNullOrWhiteSpace($ScriptPath)) { throw 'ScriptPath is required.' }
	if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "ScriptPath not found: $ScriptPath" }

	# Import vm module to access SSH helpers (idempotent import)
	$vmModule = "$PSScriptRoot/../../k2s.node.module/linuxnode/vm/vm.module.psm1"
	if (Test-Path -LiteralPath $vmModule) { Import-Module $vmModule -ErrorAction SilentlyContinue }
	if (-not (Get-Command -Name Invoke-CmdOnControlPlaneViaSSHKey -ErrorAction SilentlyContinue)) {
		throw 'Invoke-CmdOnControlPlaneViaSSHKey not available (vm module not imported)'
	}
	if (-not (Get-Command -Name Copy-ToControlPlaneViaSSHKey -ErrorAction SilentlyContinue)) {
		throw 'Copy-ToControlPlaneViaSSHKey not available (vm module not imported)'
	}
	# Ensure control plane VM is running (Hyper-V path). If WSL is enabled, skip Hyper-V start logic.
	$wslEnabled = $false
	if (Get-Command -Name Get-ConfigWslFlag -ErrorAction SilentlyContinue) {
		try { $wslEnabled = (Get-ConfigWslFlag) } catch { $wslEnabled = $false }
	}
	if (-not $wslEnabled) {
		# Import vm module for Get-IsControlPlaneRunning / Wait-ForSSHConnectionToLinuxVMViaSshKey
		$vmModule = "$PSScriptRoot/../../k2s.node.module/linuxnode/vm/vm.module.psm1"
		if (Test-Path -LiteralPath $vmModule) { Import-Module $vmModule -ErrorAction SilentlyContinue }
		$cpRunning = $false
		if (Get-Command -Name Get-IsControlPlaneRunning -ErrorAction SilentlyContinue) {
			try { $cpRunning = Get-IsControlPlaneRunning } catch { $cpRunning = $false }
		}
		if (-not $cpRunning) {
			if (-not $NoThrow) { throw 'Control plane VM not running; cannot apply Debian delta.' }
			return [pscustomobject]@{ ExitCode = 100; DurationSeconds = 0; RemotePath = $null; Success = $false }
		}
		if ($cpRunning -and (Get-Command -Name Wait-ForSSHConnectionToLinuxVMViaSshKey -ErrorAction SilentlyContinue)) {
			Write-Log '[DebPkg][VM] Waiting for SSH availability' -Console:$consoleSwitch
			# Skip SSH wait during delta update - the control plane is already verified running
			# and calling Wait-ForSSHConnectionToLinuxVMViaSshKey can hang in CI environments
			# where the outer SSH session uses -n (stdin from /dev/null), causing nested ssh.exe
			# calls to behave unexpectedly on Windows
			Write-Log '[DebPkg][VM] Skipping SSH wait (control plane already verified running)' -Console:$consoleSwitch
		}
	}

	$scriptDir = Split-Path -Parent $ScriptPath
	if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) { $WorkingDirectory = $scriptDir }
	if (-not (Test-Path -LiteralPath $WorkingDirectory)) { throw "WorkingDirectory not found: $WorkingDirectory" }

	$remoteBase = '/tmp/k2s-delta-deb'
	$remoteScriptName = Split-Path -Leaf $ScriptPath
	$remoteScriptPath = "$remoteBase/$remoteScriptName"

	Write-Log "[DebPkg][VM] Staging Debian delta script '$remoteScriptName'" -Console:$consoleSwitch
	try {
		# Ensure remote directory and make it writable by the user
		# Note: Do NOT use -Nested:$true as it removes -n flag from SSH which causes hangs
		# in CI environments where outer SSH uses stdin from /dev/null
		(Invoke-CmdOnControlPlaneViaSSHKey "sudo mkdir -p $remoteBase && sudo chown `$(whoami) $remoteBase" -Retries $RetryCount -Timeout 2).Output | Out-Null

		# Copy only the script (avoid large recursive transfers unless needed)
		Copy-ToControlPlaneViaSSHKey -Source $ScriptPath -Target $remoteBase -IgnoreErrors:$false
		
		# Convert Windows CRLF line endings to Unix LF (scripts may have been corrupted by Windows zip extraction)
		# This prevents "bash\r: No such file or directory" errors
		(Invoke-CmdOnControlPlaneViaSSHKey "sed -i 's/\r$//' $remoteScriptPath" -Retries $RetryCount -Timeout 2 -IgnoreErrors:$true).Output | Out-Null
		
		# If ancillary assets exist (packages/, etc.) we copy directory selectively
		$packagesDir = Join-Path $WorkingDirectory 'packages'
		if (Test-Path -LiteralPath $packagesDir) {
			Write-Log '[DebPkg][VM] Copying packages/ directory' -Console:$consoleSwitch
			Copy-ToControlPlaneViaSSHKey -Source $packagesDir -Target $remoteBase -IgnoreErrors:$false
		}
		
		# Copy Linux container images for air-gapped kubeadm upgrade
		# Images are required by kubeadm upgrade apply to pull control plane components
		# Check both delta root level and image-delta subdirectory for Linux images
		$deltaRoot = Split-Path -Parent $WorkingDirectory
		$imagesDirs = @(
			(Join-Path $deltaRoot 'image-delta/linux/images'),
			(Join-Path $deltaRoot 'images')
		)
		$imagesCopied = $false
		foreach ($imagesDir in $imagesDirs) {
			if ((Test-Path -LiteralPath $imagesDir) -and -not $imagesCopied) {
				$tarFiles = Get-ChildItem -LiteralPath $imagesDir -Filter '*.tar' -File -ErrorAction SilentlyContinue
				if ($tarFiles.Count -gt 0) {
					Write-Log "[DebPkg][VM] Copying $($tarFiles.Count) container images for offline kubeadm upgrade" -Console:$consoleSwitch
					(Invoke-CmdOnControlPlaneViaSSHKey "mkdir -p $remoteBase/images" -Retries $RetryCount -Timeout 2).Output | Out-Null
					Copy-ToControlPlaneViaSSHKey -Source $imagesDir -Target $remoteBase -IgnoreErrors:$false
					$imagesCopied = $true
					Write-Log '[DebPkg][VM] Container images copied successfully' -Console:$consoleSwitch
				}
			}
		}
		
		# Make executable
		(Invoke-CmdOnControlPlaneViaSSHKey "sudo chmod +x $remoteScriptPath" -Retries $RetryCount -Timeout 2 -IgnoreErrors:$false).Output | Out-Null
	} catch {
		throw "Failed to stage script in master VM: $($_.Exception.Message)"
	}

	Write-Log '[DebPkg][VM] Executing Debian delta script inside control plane VM' -Console:$consoleSwitch
	$start = Get-Date
	
	# Use background execution with polling to avoid stdin/stdout blocking in nested SSH environments
	# The script runs with nohup and writes output to a log file; we poll for completion via exit code file
	$remoteLogFile = "$remoteBase/deb-delta.log"
	$remoteExitFile = "$remoteBase/deb-delta.exit"
	
	# Cleanup any previous run artifacts
	$cleanupCmd = "sudo rm -f $remoteLogFile $remoteExitFile </dev/null 2>&1"
	(Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute $cleanupCmd -IgnoreErrors:$true -NoLog:$true).Output | Out-Null
	
	# Launch script in background with nohup, redirect all I/O, capture exit code to file
	$bgCmd = "nohup sudo $remoteScriptPath >$remoteLogFile 2>&1 </dev/null; echo `$? >$remoteExitFile &"
	# Use sh -c to ensure proper background handling
	$launchCmd = "sh -c '$bgCmd' </dev/null >/dev/null 2>&1"
	
	Write-Log '[DebPkg][VM] Launching script in background...' -Console:$consoleSwitch
	(Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute $launchCmd -IgnoreErrors:$true).Output | Out-Null
	
	# Brief wait to let the script start
	Start-Sleep -Seconds 2
	
	# Poll for exit code file with timeout
	$elapsed = $null
	$exitCode = -1
	$success = $false
	$outputAggregate = @()
	$pollInterval = 5
	$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
	
	Write-Log "[DebPkg][VM] Polling for completion (timeout=${TimeoutSeconds}s)..." -Console:$consoleSwitch
	while ((Get-Date) -lt $deadline) {
		Start-Sleep -Seconds $pollInterval
		
		# Check if exit file exists (indicates script finished)
		$checkCmd = "test -f $remoteExitFile && cat $remoteExitFile || echo 'RUNNING'"
		$checkResult = (Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute $checkCmd -IgnoreErrors:$true -NoLog:$true).Output
		
		if ($null -ne $checkResult -and $checkResult -ne 'RUNNING' -and $checkResult -match '^\d+$') {
			$exitCode = [int]$checkResult
			$success = ($exitCode -eq 0)
			break
		}
		
		Write-Log '[DebPkg][VM] Script still running...' -Console:$consoleSwitch
	}
	
	$elapsed = (Get-Date) - $start
	
	# Retrieve log output
	$logCmd = "cat $remoteLogFile 2>/dev/null || echo '(no output)'"
	$logOutput = (Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute $logCmd -IgnoreErrors:$true -NoLog:$true).Output
	if ($logOutput) {
		$outputAggregate += $logOutput
		Write-Log "[DebPkg][VM] Script output: $logOutput" -Console:$consoleSwitch
	}
	
	# Cleanup remote artifacts
	$cleanupCmd = "sudo rm -f $remoteLogFile $remoteExitFile </dev/null 2>&1"
	(Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute $cleanupCmd -IgnoreErrors:$true -NoLog:$true).Output | Out-Null
	
	if ($exitCode -eq -1) {
		# Script didn't finish within timeout
		Write-Log "[DebPkg][VM] Script execution timed out after $TimeoutSeconds seconds" -Console
		if (-not $NoThrow) { throw "Debian delta script timed out after $TimeoutSeconds seconds" }
	}
	
	$durationSec = [Math]::Round($elapsed.TotalSeconds,2)
	
	# Log the output from the Debian delta script execution
	if ($outputAggregate.Count -gt 0) {
		Write-Log "[DebPkg][VM] Script output:" -Console:$consoleSwitch
		foreach ($line in $outputAggregate) {
			if (-not [string]::IsNullOrWhiteSpace($line)) {
				Write-Log ("[DebPkg][VM]   {0}" -f $line) -Console:$consoleSwitch
			}
		}
	}
	
	Write-Log ("[DebPkg][VM] Script completed exit={0} duration={1}s" -f $exitCode, $durationSec) -Console:$consoleSwitch
	if (-not $success -and -not $NoThrow) { throw "Debian delta script returned non-zero exit code: $exitCode" }

	return [pscustomobject]@{ ExitCode = $exitCode; DurationSeconds = $durationSec; RemotePath = $remoteScriptPath; Success = $success }
}

Export-ModuleMember -Function Invoke-CommandInMasterVM -ErrorAction SilentlyContinue
# endregion
