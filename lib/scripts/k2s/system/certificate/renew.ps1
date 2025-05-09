# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Renews the kubernetes certificates

.DESCRIPTION
Renews the kubernetes certificates. The renewal is performed only if the certificate is about to expire.
However, the renewal can be enforced explicitly by the user.

.PARAMETER Force
If set to $true, then the certificate renewal is performed irrespective of expiration.

.EXAMPLE
PS> .\renew.ps1 -Force
#>

param (
    [parameter(Mandatory = $false, HelpMessage = 'If set to $true, then the certificate renewal is performed irrespective of expiration.')]
    [switch] $Force,

    [Parameter(Mandatory = $false, HelpMessage = 'If set to $true, then the logs are written into the console with more verbosity.')]
    [switch] $ShowLogs,

    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send the result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,

    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to true.')]
    [string] $MessageType
)

$infraModule =   "$PSScriptRoot/../../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule =    "$PSScriptRoot/../../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot/../../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"

Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

function Assert-CertificateExpiry() {
    Write-Log "Checking certificate expiration on the control plane..."
    $command = "sudo kubeadm certificates check-expiration -o json"
    $output = (Invoke-CmdOnControlPlaneViaSSHKey $command).Output

    $certificatesInfo = $output | ConvertFrom-Json
     Write-Log "Certificate Expiration Info"
    $certificatesInfo.certificates | ForEach-Object {
        Write-Log "Name: $($_.name), Expiration Date: $($_.expirationDate), Residual Time: $($_.residualTime), Missing: $($_.missing)"
    }

    $expiredCertificates = $certificatesInfo.certificates | Where-Object {
        $_.residualTime -le 0 -or $_.missing -eq $true
    }

    if ($expiredCertificates) {
        Write-Log "[Warning] The following certificates have expired or are missing:" -Console
        $expiredCertificates | ForEach-Object {
            Write-Log "Certificate Name: $($_.name), Expiration Date: $($_.expirationDate), Missing: $($_.missing)" -Console
        }
        return $false
    }
    Write-Log "All certificates are valid and not expired." -Console
    return $true
}

function Assert-KubeApiServerHealth {
    param (
        [int] $MaxWaitSeconds = 300,
        [int] $RetryIntervalSeconds = 10
    )

    Write-Log "Checking if kube-apiserver is ready and available..."

    $elapsedTime = 0
    while ($elapsedTime -lt $MaxWaitSeconds) {
        $command = "curl -k -s -o /dev/null -w '%{http_code}' https://localhost:6443/healthz"

        $responseCode = (Invoke-CmdOnControlPlaneViaSSHKey $command).Output

        if ($responseCode -eq "200") {
            Write-Log "kube-apiserver is ready and available." -Console
            return $true
        }

        Write-Log "kube-apiserver is not ready yet. Retrying in $RetryIntervalSeconds seconds..."
        Start-Sleep -Seconds $RetryIntervalSeconds
        $elapsedTime += $RetryIntervalSeconds
    }

    Write-Log "[ERROR] kube-apiserver did not become ready within $MaxWaitSeconds seconds." -Console
    return $false
}

function Send-ErrorToCliAndExit {
    Param(
        [string]$ErrorMessage
    )
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'certificate-renew-failure' -Message $ErrorMessage
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $ErrorMessage -Error
    exit 1
}


function Restart-ControlPlaneNode {
    Write-Log "Restarting Control Plane Node" -Console
    $controlPlaneVMHostName = Get-ConfigControlPlaneNodeHostname
    if ($(Get-VM | Where-Object Name -eq $controlPlaneVMHostName | Measure-Object).Count -eq 1 ) {
        Write-Log ('Stopping ' + $controlPlaneVMHostName + ' VM')
        Stop-VM -Name $controlPlaneVMHostName -Force -WarningAction SilentlyContinue

        Write-Log ('Starting ' + $controlPlaneVMHostName + ' VM')
        Start-VM -Name $controlPlaneVMHostName

        Wait-ForSSHConnectionToLinuxVMViaSshKey
    } else {
        $errMsg = "Unable to find control plane VM with name $controlPlaneVMHostName"
        Send-ErrorToCliAndExit -ErrorMessage $errMsg
    }
}

function Invoke-CertificateRenewalInControlPlane {
    (Invoke-CmdOnControlPlaneViaSSHKey 'sudo kubeadm certs renew all').Output | Write-Log
    Restart-ControlPlaneNode
    $healthStatus = Assert-KubeApiServerHealth
    if ($healthStatus -eq $false) {
        $errMsg = "kube-apiserver is not healthy after certificate renewal in time"
        Send-ErrorToCliAndExit -ErrorMessage $errMsg
    }
}

function Invoke-KubeConfigRefreshOnHost {
    Write-Log "Refreshing kubeconfig on host..." -Console
    Copy-KubeConfigFromControlPlaneNode
    Add-K8sContext
}

$expired = Assert-CertificateExpiry

if (($expired -eq $false) -or ($Force -eq $true)) {
    if ($Force -eq $true) {
        Write-Log "Triggering forced certificate renewal." -Console
    }
    Invoke-CertificateRenewalInControlPlane
    Invoke-KubeConfigRefreshOnHost
}

if ($EncodeStructuredOutput) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null}
}

