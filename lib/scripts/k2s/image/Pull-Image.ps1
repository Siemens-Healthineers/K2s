# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Pull container images in K2s

.DESCRIPTION
Pull container images in K2s

.PARAMETER ImageName
The image name of the image to be pulled

.PARAMETER Windows
Indicates that it is a windows image

.EXAMPLE
# Pull linux container image with name "image:v1" in K2s
PS> .\Pull-Image.ps1 -ImageName "image:v1"

.EXAMPLE
# Pull windows container image with name "image:v1" in K2s
PS> .\Pull-Image.ps1 -ImageName "image:v1" -Windows
#>

Param (
    [parameter(Mandatory = $true, HelpMessage = 'Name of the image to be pulled.')]
    [string] $ImageName,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, the image will be pulled for windows 10 node.')]
    [switch] $Windows,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$nodeModule = "$PSScriptRoot/../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"
$infraModule = "$PSScriptRoot/../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
Import-Module $nodeModule, $infraModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

if (!$Windows) {
    Write-Log "Pulling Linux image $ImageName"
    $kubeSwitchIp = Get-ConfiguredKubeSwitchIP
    $WSL = Get-ConfigWslFlag
    $tunnelProc = $null
    $sshErrFile = $null
    # In WSL2 mode the firewall blocks VM→host connections; use SSH reverse tunnel for proxy.
    $proxyAddr = "${kubeSwitchIp}:8181"

    if ($WSL) {
        Write-Log '[image-pull] Releasing port 8181 in VM if held by a stale sshd tunnel'
        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute `
            'pid=$(sudo ss -tlnp | grep '':8181'' | grep -o ''pid=[0-9][0-9]*'' | head -1 | cut -d= -f2); if [ -n "$pid" ] && [ "$(cat /proc/$pid/comm 2>/dev/null)" = "sshd" ]; then sudo kill "$pid" 2>/dev/null; fi; true' `
            -IgnoreErrors).Output | Write-Log
        Start-Sleep -Seconds 1

        Write-Log '[image-pull] Establishing SSH reverse proxy tunnel' -Console
        $sshKey = Get-SSHKeyControlPlane
        $ipControlPlane = Get-ConfiguredIPControlPlane
        $tunnelArgs = '-N', '-o', 'StrictHostKeyChecking=no', '-o', 'ExitOnForwardFailure=yes', `
            '-o', 'ServerAliveInterval=10', '-i', $sshKey, `
            '-R', "8181:${kubeSwitchIp}:8181", "remote@${ipControlPlane}"
        $sshErrFile = [System.IO.Path]::GetTempFileName()
        $tunnelProc = Start-Process -FilePath 'ssh.exe' -ArgumentList $tunnelArgs -PassThru -WindowStyle Hidden `
            -RedirectStandardError $sshErrFile
        Start-Sleep -Seconds 2
        if ($tunnelProc.HasExited) {
            $sshErrText = if (Test-Path $sshErrFile) { (Get-Content $sshErrFile -Raw).Trim() } else { '' }
            Write-Log "[image-pull] WARNING: SSH reverse tunnel exited (code $($tunnelProc.ExitCode)) - pull may fail" -Console
            if ($sshErrText) { Write-Log "[image-pull] SSH error: $sshErrText" -Console }
            $tunnelProc = $null
        }
        else {
            Write-Log "[image-pull] SSH reverse tunnel started (PID $($tunnelProc.Id))"
            $proxyAddr = '127.0.0.1:8181'
        }
    }

    # NOTE: 'exit' inside try does NOT trigger finally in PowerShell — use $pullFailed flag instead.
    $pullFailed = $false
    try {
        $success = (Invoke-CmdOnControlPlaneViaSSHKey "sudo HTTPS_PROXY=http://${proxyAddr} HTTP_PROXY=http://${proxyAddr} buildah pull $ImageName 2>&1" -Retries 5 -Timeout 600).Success
        if (!$success) {
            $pullFailed = $true
        }
    }
    finally {
        if ($null -ne $tunnelProc) {
            if (!$tunnelProc.HasExited) {
                Write-Log "[image-pull] Stopping SSH reverse proxy tunnel (PID $($tunnelProc.Id))"
                Stop-Process -Id $tunnelProc.Id -Force -ErrorAction SilentlyContinue
            }
            $tunnelProc = $null
        }
        if ($null -ne $sshErrFile -and (Test-Path $sshErrFile)) {
            Remove-Item $sshErrFile -Force -ErrorAction SilentlyContinue
        }
    }

    if ($pullFailed) {
        $errMsg = "Error pulling image '$ImageName'"
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'image-pull-failed' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }

        Write-Log $errMsg -Error
        exit 1
    }

    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null }
    }
    return
}
else {
    Write-Log "Pulling Windows image $ImageName"
    $kubeBinPath = Get-KubeBinPath
    $retries = 5
    $success = $false
    while ($retries -gt 0) {
        $retries--
        &$kubeBinPath\crictl --config $kubeBinPath\crictl.yaml pull $ImageName

        if ($?) {
            $success = $true
            break
        }
        Start-Sleep 1
    }

    if (!$success) {
        $errMsg = "Error pulling image '$ImageName'"
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'image-pull-failed' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
    
        Write-Log $errMsg -Error
        exit 1
    }
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}