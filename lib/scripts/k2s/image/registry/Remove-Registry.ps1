# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Remove a registry

.DESCRIPTION
Remove a registry

.PARAMETER RegistryName
The name of the registry to be removed

.EXAMPLE
# Add registry
PS> .\Remove-Registry.ps1 -RegistryName "ghcr.io"
#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Name of the registry')]
    [string] $RegistryName,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$clusterModule = "$PSScriptRoot/../../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$infraModule = "$PSScriptRoot/../../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"
Import-Module $clusterModule, $infraModule, $nodeModule

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

$registries = $(Get-RegistriesFromSetupJson)

if ($registries) {
    $registryExists = $registries | Where-Object { $_ -eq $RegistryName }
    if ($registryExists.Count -eq 0) {
        $errMsg = "Registry '$RegistryName' is not configured."
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code 'registry-not-configured' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }

        Write-Log $errMsg -Error
        exit 1
    }

} else {
        $errMsg = "Registry '$RegistryName' is not configured."
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code 'registry-not-configured' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
}

Write-Log "Removing registry '$RegistryName'" -Console

$authJson = (Invoke-CmdOnControlPlaneViaSSHKey 'sudo cat /root/.config/containers/auth.json' -NoLog).Output | Out-String
Remove-RegistryAuthToContainerdConfigToml -RegistryName $RegistryName -authJson $authJson

Disconnect-Nerdctl -registry $RegistryName
Disconnect-Buildah -registry $RegistryName

Remove-Registry -Name $RegistryName

Write-Log 'Restarting Windows container runtime' -Console
Stop-NssmService('kubeproxy')
Stop-NssmService('kubelet')
Restart-NssmService('containerd')
Start-NssmService('kubelet')
Start-NssmService('kubeproxy')

Remove-RegistryFromSetupJson -Name $RegistryName

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}