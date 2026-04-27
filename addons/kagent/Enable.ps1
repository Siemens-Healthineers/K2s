# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs Kagent - Kubernetes-native AI agent framework

.EXAMPLE
k2s addons enable kagent --provider openAI --api-key <your-key>
k2s addons enable kagent --provider ollama
#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'LLM provider to configure')]
    [ValidateSet('none', 'openAI', 'anthropic', 'ollama')]
    [string] $Provider = 'none',
    [parameter(Mandatory = $false, HelpMessage = 'API key for the selected LLM provider')]
    [string] $ApiKey = '',
    [parameter(Mandatory = $false, HelpMessage = 'Deploy Copilot CLI as a BYO agent')]
    [switch] $ByoCopilot = $false,
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$kagentModule = "$PSScriptRoot\kagent.module.psm1"

Import-Module $clusterModule, $infraModule, $addonsModule, $kagentModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log '[Kagent] Checking cluster status' -Console

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
    $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon 'kagent' can only be enabled for 'k2s' setup type."
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
}

$enableByoCopilot = $ByoCopilot

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'kagent' })) -eq $true) {
    if ($enableByoCopilot) {
        # Kagent already enabled — just deploy the BYO agent
        Write-Log '[Kagent] Addon already enabled, deploying Copilot CLI BYO agent' -Console
        try {
            Deploy-CopilotCliAgent
        }
        catch {
            $errMsg = "Failed to deploy Copilot CLI BYO agent: $($_.Exception.Message)"
            if ($EncodeStructuredOutput -eq $true) {
                $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
                Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                return
            }
            Write-Log $errMsg -Error
            exit 1
        }
        Write-Log '[Kagent] Copilot CLI BYO agent deployed.' -Console
        if ($EncodeStructuredOutput -eq $true) {
            Send-ToCli -MessageType $MessageType -Message @{Error = $null }
        }
        return
    }

    $errMsg = "Addon 'kagent' is already enabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

# Validate API key is provided for providers that require it
if ($Provider -notin @('none', 'ollama') -and [string]::IsNullOrWhiteSpace($ApiKey)) {
    $errMsg = "An API key is required for provider '$Provider'. Use --api-key to provide it."
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Write-Log "[Kagent] Installing Kagent with provider '$Provider'" -Console

try {
    Install-KagentViaHelm -Provider $Provider -ApiKey $ApiKey
}
catch {
    $errMsg = "Failed to install Kagent via Helm: $($_.Exception.Message)"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

Write-Log '[Kagent] Checking Kagent status' -Console
$kagentReady = Wait-ForKagentAvailable
if ($kagentReady -ne $true) {
    $errMsg = "Kagent pods could not become ready. Please use 'kubectl describe pods -n kagent' for more details.`nInstallation of Kagent failed."
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'kagent' })

# Deploy Copilot CLI BYO agent if requested
if ($enableByoCopilot) {
    Write-Log '[Kagent] Deploying Copilot CLI as BYO agent' -Console
    try {
        Deploy-CopilotCliAgent
    }
    catch {
        $errMsg = "Failed to deploy Copilot CLI BYO agent: $($_.Exception.Message)"
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }
}

Write-KagentUsageForUser

Write-Log '[Kagent] Installation of Kagent addon finished.' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
