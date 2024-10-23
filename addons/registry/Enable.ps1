# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Enables k2s-registry in the cluster to the private-registry namespace

.DESCRIPTION
The local registry allows to push/pull images to/from the local volume of KubeMaster.
Each node inside the cluster can connect to the registry.

.EXAMPLE
# For k2sSetup
powershell <installation folder>\addons\registry\Enable.ps1
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Use default credentials')]
    [switch] $UseDefaultCredentials = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Nodeport for registry access')]
    [Int] $Nodeport = 30500,
    [parameter(Mandatory = $false, HelpMessage = 'Enable ingress addon')]
    [ValidateSet('nginx', 'traefik', 'none')]
    [string] $Ingress = 'none',
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$nodeModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.node.module/k2s.node.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$registryModule = "$PSScriptRoot\registry.module.psm1"

Import-Module $infraModule, $clusterModule, $nodeModule, $addonsModule, $registryModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Checking cluster status' -Console

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

$setupInfo = Get-SetupInfo
if ($setupInfo.Name -ne 'k2s') {
    $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon 'registry' can only be enabled for 'k2s' setup type."
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'registry' })) -eq $true) {
    $errMsg = "Addon 'registry' is already enabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

if ($Ingress -ne 'none') {
    Enable-IngressAddon -Ingress:$Ingress
}

# Create secrets
(Invoke-Kubectl -Params 'create', 'namespace', 'registry').Output | Write-Log

# Apply registry pod with persistent volume
Write-Log 'Creating local registry' -Console
(Invoke-Kubectl -Params 'apply', '-k', "$PSScriptRoot\manifests\registry").Output | Write-Log

$kubectlCmd = (Invoke-Kubectl -Params 'wait', '--timeout=60s', '--for=condition=Ready', '-n', 'registry', 'pod/registry')
Write-Log $kubectlCmd.Output
if (!$kubectlCmd.Success) {
    $errMsg = 'k2s.registry.local did not start in time! Please disable addon and try to enable again!'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Add-HostEntries -Url 'k2s.registry.local'

# Create secret for enabling all the nodes in the cluster to authenticate with private registry
#(Invoke-Kubectl -Params 'create', 'secret', 'docker-registry', 'k2s-registry', "--docker-server=$registryName", "--docker-username=$username", "--docker-password=$password").Output | Write-Log

# Start-Sleep 2

# Connect-Buildah -username $username -password $password -registry $registryName

# $authJson = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo cat /root/.config/containers/auth.json').Output | Out-String

# Connect-Nerdctl -username $username -password $password -registry $registryName

# # set authentification for containerd
# Set-Containerd-Config -registryName $registryName -authJson $authJson

# Restart-Services | Write-Log -Console

# if (!$?) {
#     $errMsg = 'Login to private registry not possible! Please disable addon and try to enable it again!'
#     if ($EncodeStructuredOutput -eq $true) {
#         $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
#         Send-ToCli -MessageType $MessageType -Message @{Error = $err }
#         return
#     }

#     Write-Log $errMsg -Error
#     exit 1
# }

&"$PSScriptRoot\Update.ps1"

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'registry' })

#Set-ConfigLoggedInRegistry -Value $registryName

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}