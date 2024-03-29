# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

&$PSScriptRoot\..\smallsetup\common\GlobalVariables.ps1
. $PSScriptRoot\..\smallsetup\common\GlobalFunctions.ps1

$logModule = "$PSScriptRoot\..\smallsetup\ps-modules\log\log.module.psm1"
$statusModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.cluster.module\status\status.module.psm1"
$errorsModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.infra.module\errors\errors.module.psm1"

Import-Module $logModule, $statusModule, $errorsModule

$script = $MyInvocation.MyCommand.Name
$ConfigKey_EnabledAddons = 'EnabledAddons'
$hooksDir = "$PSScriptRoot\hooks"
$backupFileName = 'backup_addons.json'

function Get-AddonsConfig {
    $function = $MyInvocation.MyCommand.Name

    Write-Log "[$script::$function] Retrieving addons config.."

    return (Get-ConfigValue -Path $global:SetupJsonFile -Key $ConfigKey_EnabledAddons)
}

function Get-ScriptRoot {
    return $PSScriptRoot
}

function Enable-AddonFromConfig {
    param (
        [Parameter(Mandatory = $false)]
        [pscustomobject]$Config = $(throw 'Config object not specified')
    )
    if ($null -eq $Config.Name) {
        Write-Warning "Invalid addon config '$Config' found, skipping it."
        return
    }

    $root = Get-ScriptRoot
    $enableCmdPath = "$root\$($Config.Name)\Enable.ps1"

    if ((Test-Path $enableCmdPath) -ne $true) {
        Write-Warning "Addon '$($Config.Name)' seems to be deprecated, skipping it."
        return
    }

    Write-Log "Re-enabling addon '$($Config.Name)'.."

    & $enableCmdPath -Config $Config

    Write-Log "Addon '$($Config.Name)' re-enabled."
}

function Invoke-BackupRestoreHooks {
    param (
        [parameter(Mandatory = $false)]
        [ValidateSet('Backup', 'Restore')]
        [string]$HookType = $(throw 'Hook type not specified'),
        [Parameter(Mandatory = $false)]
        [string]$BackupDir = $(throw 'Back-up directory not specified')
    )
    if ((Test-Path -Path $hooksDir) -ne $true) {
        Write-Log 'Addons hooks dir not existing, skipping..'
        return
    }

    $hooksFilter = "*.$HookType.ps1"

    Write-Log "Executing addons hooks with hook type '$HookType'.."

    $executionCount = 0

    Get-ChildItem -Path $hooksDir -Filter $hooksFilter -Force | ForEach-Object {
        Write-Log "  Executing '$($_.FullName)'.."
        & "$($_.FullName)" -BackupDir $BackupDir
        $executionCount++
    }

    if ($executionCount -eq 0) {
        Write-Log 'No back-up/restore hooks found.'
    }
}

function ConvertTo-NewConfigStructure {
    param (
        [Parameter(Mandatory = $false)]
        [pscustomobject]$Config = $(throw 'Config not specified.')
    )
    $newConfig = [System.Collections.ArrayList]@()

    foreach ($addon in $Config) {
        $newAddon = $addon
        if ($addon -is [string]) {
            $newAddon = [pscustomobject]@{Name = $addon }

            Write-Information "Config for addon '$addon' migrated."
        }
        elseif ($addon -isnot [pscustomobject]) {
            throw "Unexpected addon config type '$($addon.GetType().Name)'"
        }

        $newConfig.Add($newAddon) > $null
    }

    return $newConfig
}

function Find-AddonManifests {
    param (
        [Parameter(Mandatory = $false)]
        [string]$Directory = $(throw 'Directory not specified')
    )
    return Get-ChildItem -File -Recurse -Depth 1 -Path $Directory -Filter 'addon.manifest.yaml' | ForEach-Object { $_.FullName }
}

function Get-EnabledAddons {
    $function = $MyInvocation.MyCommand.Name

    Write-Log "[$script::$function] Getting enabled addons.."

    $config = Get-AddonsConfig

    if ($null -eq $config) {
        Write-Log "[$script::$function] No addons config found"

        return @{Addons = $null }
    }

    Write-Log "[$script::$function] Addons config found"

    $enabledAddons = @{Addons = [System.Collections.ArrayList]@() }

    $config | ForEach-Object { 
        Write-Log "[$script::$function] found addon '$($_.Name)'"
        $enabledAddons.Addons.Add($_.Name) | Out-Null
    }    

    return $enabledAddons
}

<#
.SYNOPSIS
    Adds an enabled addon to setup.json
.DESCRIPTION
    Adds an addon to json array "EnabledAddons" in Setup.json. If the array is not present, then it is created and then the enabled addon
    into the array. The addon object must contain a 'Name' property
.PARAMETER Addon
    The addon object containing a 'Name' property
.EXAMPLE
    Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'dashboard' })
#>
function Add-AddonToSetupJson() {
    param (
        [Parameter(Mandatory = $false)]
        [pscustomobject]$Addon = $(throw 'Please specify the addon.')
    )
    if ($Addon -eq $null) {
        throw 'Addon not specified'
    }
    if ($null -eq ($Addon | Get-Member -MemberType Properties -Name 'Name')) {
        throw "Addon does not contain a property with name 'Name'"
    }

    $parsedSetupJson = Get-Content -Raw $global:SetupJsonFile | ConvertFrom-Json

    $enabledAddonMemberExists = Get-Member -InputObject $parsedSetupJson -Name $ConfigKey_EnabledAddons -MemberType Properties
    if (!$enabledAddonMemberExists) {
        $parsedSetupJson = $parsedSetupJson | Add-Member -NotePropertyMembers @{EnabledAddons = @() } -PassThru
    }
    $addonAlreadyExists = $parsedSetupJson.EnabledAddons | Where-Object { $_.Name -eq $Addon.Name }
    if (!$addonAlreadyExists) {
        $parsedSetupJson.EnabledAddons += $Addon
        $parsedSetupJson | ConvertTo-Json -Depth 100 | Set-Content -Force $global:SetupJsonFile -Confirm:$false
    }
}

<#
.SYNOPSIS
    Removes an enabled addon from setup.json
.DESCRIPTION
    From an addon from json array "EnabledAddons" in Setup.json. If the array is empty after the remove operation,
    then the json array is removed from Setup.json
.PARAMETER Name
    Name of the enabled addon
.EXAMPLE
    Remove-AddonFromSetupJson -Name "DummyAddon"
#>
function Remove-AddonFromSetupJson([string]$Name) {
    Write-Log "Removing '$Name' from addons config.."

    $parsedSetupJson = Get-Content -Raw $global:SetupJsonFile | ConvertFrom-Json

    $enabledAddonMemberExists = Get-Member -InputObject $parsedSetupJson -Name $ConfigKey_EnabledAddons -MemberType Properties
    if ($enabledAddonMemberExists) {
        $enabledAddons = $parsedSetupJson.EnabledAddons
        $newEnabledAddons = @($enabledAddons | Where-Object { $_.Name -ne $Name })
        if ($newEnabledAddons) {
            $parsedSetupJson.EnabledAddons = $newEnabledAddons
        }
        else {
            $parsedSetupJson.PSObject.Properties.Remove($ConfigKey_EnabledAddons)
        }
        $parsedSetupJson | ConvertTo-Json -Depth 100 | Set-Content -Force $global:SetupJsonFile -Confirm:$false
    }
}

function Install-DebianPackages {
    param (
        [parameter()]
        [string] $addon,
        [parameter()]
        [string[]]$packages
    )

    foreach ($package in $packages) {
        if (!(Get-DebianPackageAvailableOffline -addon $addon -package $package)) {
            ExecCmdMaster "mkdir -p .${addon}/${package} && cd .${addon}/${package} && sudo chown -R _apt:root ."
            ExecCmdMaster "cd .${addon}/${package} && sudo apt-get download $package" -Retries 2 -RepairCmd 'sudo apt --fix-broken install'
            ExecCmdMaster "cd .${addon}/${package} && sudo DEBIAN_FRONTEND=noninteractive apt-get --reinstall install -y --no-install-recommends --no-install-suggests --simulate ./${package}*.deb | grep 'Inst ' | cut -d ' ' -f 2 | sort -u | xargs sudo apt-get download" -Retries 2 -RepairCmd 'sudo apt --fix-broken install'
        }

        Write-Log "Installing $package offline."
        ExecCmdMaster "sudo dpkg -i .${addon}/${package}/*.deb 2>&1"
    }
}

function Get-DebianPackageAvailableOffline {
    param (
        [parameter()]
        [string] $addon,
        [parameter()]
        [string]$package
    )

    # NOTE: DO NOT USE `ExecCmdMaster` here to get the return value.
    ssh.exe -n -o StrictHostKeyChecking=no -i $global:LinuxVMKey $global:Remote_Master "[ -d .${addon}/${package} ]"
    if (!$?) {
        return $false
    }

    Write-Log "$package available offline."

    return $true
}

<#
.SYNOPSIS
    Checks if a specific addon is enabled.
.DESCRIPTION
    Checks if a specific addon is enabled by looking up the given name in the list of enabled addons config.
.PARAMETER Name
    Name of the addon in question
#>
function Test-IsAddonEnabled {
    param (
        [parameter(Mandatory = $false)]
        [string] $Name = $(throw 'Name not specified')
    )
    $addons = Get-AddonsConfig
    foreach ($addon in $addons) {
        if ($addon.Name -eq $Name) {
            return $true
        }
    }
    return $false
}

<#
.SYNOPSIS
    Invokes addons hooks.
.DESCRIPTION
    Invokes all addons hooks matching the hook type.
.PARAMETER HookType
    The type of hook, e.g. 'AfterStart' after starting the cluster
#>
function Invoke-AddonsHooks {
    param (
        [parameter(Mandatory = $false)]
        [ValidateSet('AfterStart', 'AfterUninstall')]
        [string]$HookType = $(throw 'No hook type specified')
    )
    if ((Test-Path -Path $hooksDir) -ne $true) {
        Write-Log 'Addons hooks dir not existing, skipping..'
        return
    }

    $hooksFilter = "*.$HookType.ps1"

    Write-Log "Executing addons hooks with hook type '$HookType'..."

    $executionCount = 0

    Get-ChildItem -Path $hooksDir -Filter $hooksFilter -Force | ForEach-Object {
        Write-Log "  Executing $($_.FullName) ..."
        Invoke-Script -FilePath $_.FullName
        $executionCount++
    }

    if ($executionCount -eq 0) {
        Write-Log 'No addons hooks found.'
    }

    if ($HookType -eq 'AfterUninstall') {
        if (Test-Path $hooksDir) {
            Remove-Item -Path "$hooksDir" -Force -Recurse -ErrorAction SilentlyContinue
        }
    }
}

<#
.SYNOPSIS
    Copies script files to the hooks directory.
.DESCRIPTION
    Copies given script files to the addons hooks directory.
.PARAMETER Scripts
    Array of script file paths
#>
function Copy-ScriptsToHooksDir {
    param (
        [Parameter(ValueFromPipeline, Mandatory = $false)]
        [System.Collections.ArrayList]$ScriptPaths = $(throw 'No script file paths specified')
    )
    process {
        if ((Test-Path -Path $hooksDir) -ne $true) {
            Write-Log 'Addons hooks dir not existing, creating it..'
            New-Item -Path $hooksDir -ItemType Directory -Force | Out-Null
        }

        Write-Log 'Copying addons hooks..'

        foreach ($path in $ScriptPaths) {
            if ((Test-Path -Path $path) -ne $true) {
                Write-Warning "Cannot copy addon hook '$path' because it does not exist."
                continue
            }

            $sourceFileName = Get-FileName -FilePath $path
            $targetPath = "$hooksdir\$sourceFileName"

            Copy-Item -Path $path -Destination $targetPath -Force

            Write-Log "  Hook '$sourceFileName' copied."
        }
    }
}

<#
.SYNOPSIS
    Remove script files from the hooks directory
.DESCRIPTION
    Removes script files from the hooks directory
.PARAMETER ScriptNames
    Array of script file names to be removed from the hooks directory
#>
function Remove-ScriptsFromHooksDir {
    param (
        [Parameter(ValueFromPipeline, Mandatory = $false)]
        [System.Collections.ArrayList]$ScriptNames = $(throw 'No script file names specified')
    )
    process {
        if ((Test-Path -Path $hooksDir) -ne $true) {
            Write-Log 'Addons hooks dir not existing, nothing to remove.'
            return
        }

        Write-Log 'Removing addons hooks..'

        foreach ($name in $ScriptNames) {
            $path = "$hooksdir\$name"

            if ((Test-Path -Path $path) -ne $true) {
                Write-Warning "Cannot remove addon hook '$path' because it does not exist."
                continue
            }

            Remove-Item -Path $path -Force

            Write-Log "  Hook '$name' removed."
        }
    }
}

<#
.SYNOPSIS
    Loads the config of a given addon.
.DESCRIPTION
    Loads and returns the config of a given addon if existing. Otherwise, returns $null.
.PARAMETER Name
    Name of the addon in question
#>
function Get-AddonConfig {
    param (
        [parameter(Mandatory = $false)]
        [string] $Name = $(throw 'Name not specified')
    )
    $addons = Get-AddonsConfig
    foreach ($addon in $addons) {
        if ($addon.Name -eq $Name) {
            return $addon
        }
    }
    return $null
}

<#
.SYNOPSIS
Creates an addons backup

.DESCRIPTION
Creates an addons backup with the following steps:
- loads addons config
- migrates config to current structure
- creates config backup
- invokes the addons backup hooks for addon-specific backup tasks, e.g. creating data backup

.PARAMETER BackupDir
Directory where the addons backup shall be stored to
#>
function Backup-Addons {
    param (
        [Parameter(Mandatory = $false, HelpMessage = 'Back-up directory to write data to (gets created if not existing).')]
        [string]$BackupDir = $(throw 'Please specify the back-up directory.')
    )
    Write-Log 'Loading and migrating addons config..'
    $config = Get-AddonsConfig

    if ($null -eq $config) {
        Write-Log 'No addons to back-up, skipping.'
        return
    }

    if ((Test-Path $BackupDir) -ne $true) {
        Write-Log 'Addons backup dir not existing, creating it..'
        New-Item -Path $BackupDir -ItemType Directory -Force | Out-Null
    }

    $([array]$migratedConfig = ConvertTo-NewConfigStructure -Config $config) 6>&1 | ForEach-Object { Write-Log $_ }

    $backupContentRoot = [pscustomobject]@{Config = $migratedConfig }
    $backupFilePath = (Join-Path $BackupDir $backupFileName)

    $backupContentRoot | ConvertTo-Json -Depth 100 | Set-Content -Force $backupFilePath -Confirm:$false

    Write-Log "Addons config migrated and saved to '$backupFilePath'."
    Write-Log 'Backing-up addons data..'

    Invoke-BackupRestoreHooks -HookType Backup -BackupDir $BackupDir

    Write-Log 'Addons data backed-up.'
}

<#
.SYNOPSIS
Restores addons from backup

.DESCRIPTION
Restores addons from addons config backup with the following steps:
- loads the config backup
- enables all configured addons
- invokes the addons restore hooks for addon-specific restore tasks, e.g. restoring data from backup

.PARAMETER BackupDir
Directory where the addons backup is located

.NOTES
- addons-specific config section gets passed to the addons restore hooks
- if addons appear to be obsolete, i.e. addons do not exist in the current version, the restore of obsolete addons will be skipped
#>
function Restore-Addons {
    param (
        [Parameter(Mandatory = $false, HelpMessage = 'Back-up directory to restore data from.')]
        [string]$BackupDir = $(throw 'Please specify the back-up directory.')
    )
    Write-Log 'Restoring addons..'

    $backupFilePath = (Join-Path $BackupDir $backupFileName)

    if ((Test-Path $backupFilePath) -ne $true) {
        Write-Log 'Addons config file back-up not found, skipping.'
        return
    }

    $backupContentRoot = Get-Content $backupFilePath -Raw | ConvertFrom-Json

    foreach ($addonConfig in $backupContentRoot.Config) {
        Enable-AddonFromConfig -Config $addonConfig
    }

    Write-Log 'Restoring addons data..'

    Invoke-BackupRestoreHooks -HookType Restore -BackupDir $BackupDir

    Write-Log 'Addons fully restored.'
}

function Get-AddonStatus {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Name of the addon')]
        [string] $Name = $(throw 'Name not specified'),
        [parameter(Mandatory = $false, HelpMessage = 'Directory path of the addon')]
        [string] $Directory = $(throw 'Directory not specified')
    )
    $status = @{Error = $null }

    if ((Test-Path -Path $Directory) -ne $true) {
        $status.Error = New-Error -Severity Warning -Code (Get-ErrCodeAddonNotFound) -Message "Addon '$Name' not found in directory '$Directory'." 
        return $status
    }
    
    $addonStatusScript = "$Directory\Get-Status.ps1"
    if ((Test-Path -Path $addonStatusScript) -ne $true) {
        $status.Error = New-Error -Severity Warning -Code 'no-addon-status' -Message "Addon '$Name' does not provide detailed status information." 
        return $status
    }

    $systemError = Test-SystemAvailability -Structured
    if ($systemError) {
        $status.Error = $systemError
        return $status
    }

    $isEnabled = Test-IsAddonEnabled -Name $Name

    $status.Enabled = $isEnabled
    if ($isEnabled -ne $true) {
        return $status
    }

    $status.Props = Invoke-Script -FilePath $addonStatusScript

    return $status
}

function Get-ErrCodeAddonAlreadyDisabled { 'addon-already-disabled' }

function Get-ErrCodeAddonAlreadyEnabled { 'addon-already-enabled' }

function Get-ErrCodeAddonEnableFailed { 'addon-enable-failed' }

function Get-ErrCodeAddonNotFound { 'addon-not-found' }

Export-ModuleMember -Function Get-EnabledAddons, Add-AddonToSetupJson, Remove-AddonFromSetupJson,
Install-DebianPackages, Get-DebianPackageAvailableOffline, Test-IsAddonEnabled, Invoke-AddonsHooks, Copy-ScriptsToHooksDir,
Remove-ScriptsFromHooksDir, Get-AddonConfig, Backup-Addons, Restore-Addons, Get-AddonStatus, Find-AddonManifests,
Get-ErrCodeAddonAlreadyDisabled, Get-ErrCodeAddonAlreadyEnabled, Get-ErrCodeAddonEnableFailed, Get-ErrCodeAddonNotFound