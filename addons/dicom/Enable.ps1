# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Enables dicom server for the k2s cluster.

.DESCRIPTION
The "dicom" addons enables dicom server for the k2s cluster.

#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [ValidateSet('nginx', 'traefik', 'none')]
    [string] $Ingress = 'none',
    [ValidateSet('smb', 'none')]
    [string] $Storage = 'none',    
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType,
    [parameter(Mandatory = $false, HelpMessage = 'Override storage directory for Orthanc data')]
    [string] $StorageDir
)
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$dicomModule = "$PSScriptRoot\dicom.module.psm1"
$viewerModule = "$PSScriptRoot\..\viewer\viewer.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule, $dicomModule, $viewerModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Checking cluster status' -Console

# get addon name from folder path
$addonName = Get-AddonNameFromFolderPath -BaseFolderPath $PSScriptRoot

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
    $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon $addonName can only be enabled for 'k2s' setup type."  
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = $addonName })) -eq $true) {
    $errMsg = "Addon $addonName is already enabled, nothing to do."

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

if ($Storage -ne 'none') {
    Enable-StorageAddon -Storage:$Storage

    if ($StorageDir) {
        Write-Log "Validating StorageDir '$StorageDir' against SMB config..." -Console
        $orthancConfigPath = "$PSScriptRoot\manifests\dicom\orthanc.json"
        $chosenStorageDir = $null
        $smbConfigPath = "$PSScriptRoot\..\storage\smb\config\SmbStorage.json"
        $smbConfig = Get-Content $smbConfigPath | ConvertFrom-Json

        # Support both array and single object for SmbStorage.json
        $linuxMountPaths = @()
        if ($smbConfig -is [System.Collections.IEnumerable]) {
            foreach ($entry in $smbConfig) {
                if ($entry.linuxMountPath) {
                    $linuxMountPaths += $entry.linuxMountPath
                }
            }
        } elseif ($smbConfig.linuxMountPath) {
            $linuxMountPaths += $smbConfig.linuxMountPath
        }
        if ($linuxMountPaths -contains $StorageDir) {
            Write-Log "StorageDir '$StorageDir' found in SMB config." -Console
            $chosenStorageDir = $StorageDir
        } else {
            Write-Warning "Provided StorageDir '$StorageDir' does not match any SMB linuxMountPath. Using default: $($linuxMountPaths[0])"
            $chosenStorageDir = if ($linuxMountPaths.Count -gt 0) { $linuxMountPaths[0] } else { $null }
        }
        Update-OrthancStorageConfig -orthancConfigPath $orthancConfigPath -newStorageDir $chosenStorageDir
        Write-Log "Orthanc storage directory set to: $chosenStorageDir" -Console
    }
}

# --- Begin: SMB storage config adaptation and orthanc.json preservation ---
function Update-OrthancStorageConfig {
    param(
        [string]$orthancConfigPath,
        [string]$newStorageDir
    )
    $orthancConfig = $null
    if (Test-Path $orthancConfigPath) {
        $orthancConfig = Get-Content $orthancConfigPath -Raw | ConvertFrom-Json
        $orthancConfig.StorageDirectory = $newStorageDir
        $orthancConfig.IndexDirectory = $newStorageDir
    } else {
        $orthancConfig = @{
            StorageDirectory = $newStorageDir
            IndexDirectory   = $newStorageDir
        }
    }
    $orthancConfig | ConvertTo-Json -Depth 100 -Compress | Set-Content -Path $orthancConfigPath -Force
}


# --- End: SMB storage config adaptation and orthanc.json preservation ---

$dicomConfig = Get-DicomConfig
(Invoke-Kubectl -Params 'apply', '-f', "$dicomConfig\dicom-namespace.yaml").Output | Write-Log

Write-Log 'Determine storage setup' -Console
$StorageUsage = 'default'
if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'storage' })) -eq $true) {
    if ($Storage -ne 'none') {
        $pvConfig = Get-PVConfigStorage
        (Invoke-Kubectl -Params 'apply' , '-k', $pvConfig).Output | Write-Log
        $StorageUsage = 'storage'
        Write-Log 'Use storage addon for storing DICOM data' -Console
    }
    else {
        $answer = Read-Host 'Addon storage is enabled. Would you like to reuse the storage provided by that addon for the DICOM data ? (y/N)'
        if ($answer -ne 'y') {
            $pvConfig = Get-PVConfigDefault
            (Invoke-Kubectl -Params 'apply' , '-k', $pvConfig).Output | Write-Log
            Write-Log 'Use default storage for DICOM data' -Console
        }
        else {
            $pvConfig = Get-PVConfigStorage
            (Invoke-Kubectl -Params 'apply' , '-k', $pvConfig).Output | Write-Log
            $StorageUsage = 'storage'
            Write-Log 'Use storage addon for storing DICOM data' -C
        }
    }
}
else {
    $pvConfig = Get-PVConfigDefault
    (Invoke-Kubectl -Params 'apply' , '-k', $pvConfig).Output | Write-Log
    Write-Log 'Use default storage for DICOM data' -Console
}

Write-Log 'Installing dicom server and client..' -Console
$applyResult = Invoke-Kubectl -Params 'apply', '-k', $dicomConfig
$applyResult.Output | Write-Log

Write-Log 'Checking dicom addon status' -Console
Write-Log 'Waiting for Pods..'

# Check initial deployment status
$deploymentSuccess = $true
$errMsg = ''

# Check if deployments exist and are running properly
Write-Log 'Verifying DICOM resources were created and running...' -Console
Start-Sleep -Seconds 5  # Give a moment for resources to be registered

$deploymentsCheck = Invoke-Kubectl -Params 'get', 'deployments', '-n', 'dicom'
if (!$deploymentsCheck.Success -or $deploymentsCheck.Output -match "No resources found") {
    $deploymentSuccess = $false
    $errMsg = 'No DICOM deployments found in the namespace. This often indicates YAML formatting issues in the manifest files.'
    
    # Check for any events that might provide more info about failures
    Write-Log "Checking for namespace events that might explain the failure..." -Console
    $events = Invoke-Kubectl -Params 'get', 'events', '-n', 'dicom', '--sort-by=.metadata.creationTimestamp'
    if ($events.Success) {
        $events.Output | Write-Log
    }
} else {
    # Continue with status checks for specific deployments
    $dicomExists = $deploymentsCheck.Output -match "dicom"
    $postgresExists = $deploymentsCheck.Output -match "postgres"
    
    if (!$dicomExists) {
        Write-Log "The 'dicom' deployment was not created" -Error
        $deploymentSuccess = $false
    }
    
    if (!$postgresExists) {
        Write-Log "The 'postgres' deployment was not created" -Error
        $deploymentSuccess = $false
    }
    
    # If all deployments exist, check their status
    if ($deploymentSuccess) {
        $kubectlCmd = (Invoke-Kubectl -Params 'rollout', 'status', 'deployments', '-n', 'dicom', '--timeout=180s')
        Write-Log $kubectlCmd.Output
        if (!$kubectlCmd.Success) {
            $deploymentSuccess = $false
            $errMsg = 'DICOM deployments could not be deployed!'
        }
    } else {
        $errMsg = 'Not all required DICOM deployments were created.'
    }

    # DICOM addon only uses deployments, no need to check for StatefulSets or DaemonSets
}

if (!$deploymentSuccess) {
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

# Handle Linkerd annotations if necessary and ensure pods are ready
$linkerdHandlingSuccess = Restart-PodsWithLinkerdAnnotation -namespace 'dicom' -timeoutSeconds 300
if (!$linkerdHandlingSuccess) {
    $errMsg = 'Failed to restart pods with Linkerd annotations or pods did not become ready in time!'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = $addonName; StorageUsage = $StorageUsage })

# Call Update.ps1 to update ingress and other configurations
# Skip Linkerd restart when enabling since we just deployed the pods
&"$PSScriptRoot\Update.ps1" -SkipLinkerdRestart

# adapt other addons
Update-Addons -AddonName $addonName

Write-Log 'dicom server installed successfully'

Write-UsageForUser
Write-BrowserWarningForUser

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}