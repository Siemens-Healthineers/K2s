# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

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
&$PSScriptRoot\..\common\GlobalVariables.ps1
. $PSScriptRoot\..\common\GlobalFunctions.ps1

$registryFunctionsModule = "$PSScriptRoot\RegistryFunctions.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
$imageFunctionsModule = "$PSScriptRoot\ImageFunctions.module.psm1"
$infraModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"

Import-Module $registryFunctionsModule, $clusterModule, $imageFunctionsModule, $infraModule -DisableNameChecking

function Invoke-NssmCommandWithTimeout {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList,
        [Parameter(Mandatory = $false)]
        [int]$TimeoutInSeconds = 90,
        [Parameter(Mandatory = $false)]
        [switch]$ContinueOnTimeout = $false
    )

    $nssmExe = Join-Path $global:NssmInstallDirectory 'nssm'
    if (-not (Test-Path $nssmExe)) {
        throw "nssm executable not found at '$nssmExe'."
    }

    Write-Log "Invoking nssm with timeout ${TimeoutInSeconds}s: $($ArgumentList -join ' ')"
    $process = Start-Process -FilePath $nssmExe -ArgumentList $ArgumentList -NoNewWindow -PassThru
    if (-not $process.WaitForExit($TimeoutInSeconds * 1000)) {
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
        catch {
            Write-Log "Failed to stop timed-out nssm process id '$($process.Id)': $($_.Exception.Message)"
        }

        $timeoutMessage = "nssm command timed out after ${TimeoutInSeconds}s: $($ArgumentList -join ' ')"
        if ($ContinueOnTimeout) {
            Write-Log "$timeoutMessage. Continuing without blocking image workflow."
            return $false
        }

        throw $timeoutMessage
    }

    if ($process.ExitCode -ne 0) {
        throw "nssm command failed with exit code $($process.ExitCode): $($ArgumentList -join ' ')"
    }

    return $true
}

if (-not (Get-Command -Name Write-Log -ErrorAction SilentlyContinue)) {
    Import-Module $infraModule -DisableNameChecking
}

if (-not (Get-Module -Name $infraModule -ListAvailable)) { Initialize-Logging -ShowLogs:$ShowLogs }

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

$registries = $(Get-RegistriesFromSetupJson)
if ($null -eq $registries) {
    $errMsg = 'No registries configured.'    
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code 'no-registry-configured' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

if ($registries.Contains($RegistryName) -ne $true) {
    $errMsg = "Registry $RegistryName not configured, please add it first."    
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code 'registry-not-configured' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

Write-Log "Trying to login into $RegistryName" -Console

Login-Buildah -registry $RegistryName

# Add dockerd parameters and restart docker daemon to push nondistributable artifacts and use insecure registry
if ($setupInfo.Name -eq $global:SetupType_k2s -or $setupInfo.Name -eq $global:SetupType_BuildOnlyEnv) {
    $storageLocalDrive = Get-StorageLocalDrive
    Write-Log "Configuring docker daemon for registry '$RegistryName'" -Console
    &"$global:NssmInstallDirectory\nssm" set docker AppParameters --exec-opt isolation=process --data-root "$storageLocalDrive\docker" --log-level debug --allow-nondistributable-artifacts "$RegistryName" --insecure-registry "$RegistryName" | Out-Null

    $dockerService = Get-Service -Name 'docker' -ErrorAction SilentlyContinue
    $dockerServiceStatus = if ($null -eq $dockerService) { 'NotFound' } else { $dockerService.Status.ToString() }
    Write-Log "Docker service status before nssm action: $dockerServiceStatus" -Console

    $nssmActionSucceeded = $false
    if ($dockerServiceStatus -eq 'Running') {
        $nssmActionSucceeded = Invoke-NssmCommandWithTimeout -ArgumentList @('restart', 'docker') -TimeoutInSeconds 90 -ContinueOnTimeout
    }
    else {
        $nssmActionSucceeded = Invoke-NssmCommandWithTimeout -ArgumentList @('start', 'docker') -TimeoutInSeconds 90 -ContinueOnTimeout
    }

    if ($nssmActionSucceeded) {
        Login-Docker -registry $RegistryName
    }
    else {
        Write-Log "Skipping docker login because docker service action timed out. Buildah login remains active for Linux image push workflows." -Console
    }
}

Set-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_LoggedInRegistry -Value $RegistryName

Write-Log "Login to '$RegistryName' was successful." -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}