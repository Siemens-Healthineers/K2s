# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

$infraModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
$nodeModule = "$PSScriptRoot/../lib/modules/k2s/k2s.node.module/k2s.node.module.psm1"

Import-Module $infraModule, $clusterModule, $nodeModule

$script = $MyInvocation.MyCommand.Name
$ConfigKey_EnabledAddons = 'EnabledAddons'
$hooksDir = "$PSScriptRoot\hooks"
$backupFileName = 'backup_addons.json'

function Get-FileName {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $FilePath = $(throw 'FilePath not specified')
    )
    return [System.IO.Path]::GetFileName($FilePath)
}

function Invoke-Script {
    param (
        [parameter(Mandatory = $false)]
        [string] $FilePath = $(throw 'FilePath not specified')
    )
    if ((Test-Path $FilePath) -ne $true) {
        throw "Path to '$FilePath' not existing"
    }
    & $FilePath
}

function Get-AddonsConfig {
    $function = $MyInvocation.MyCommand.Name

    Write-Log "[$script::$function] Retrieving addons config.."

    return (Get-ConfigValue -Path (Get-SetupConfigFilePath) -Key $ConfigKey_EnabledAddons)
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

    $dirName = $Config.Name
    $addonName = $Config.Name
    if ($null -ne $Config.Implementation) {
        $dirName += "\$($Config.Implementation)"
        $addonName += " $($Config.Implementation)"
    }

    $root = Get-ScriptRoot
    $enableCmdPath = "$root\$dirName\Enable.ps1"

    if ((Test-Path $enableCmdPath) -ne $true) {
        Write-Warning "Addon '$($Config.Name)' seems to be deprecated, skipping it."
        return
    }

    Write-Log "Re-enabling addon '$addonName'.."

    & $enableCmdPath -Config $Config

    Write-Log "Addon '$addonName' re-enabled."
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
            switch ($addon) {
                "gateway-nginx" { $newAddon = [pscustomobject]@{Name = "gateway-api"} }
                "ingress-nginx" { $newAddon = [pscustomobject]@{Name = "ingress"; Implementation = @("nginx") } }
                "traefik" { $newAddon = [pscustomobject]@{Name = "ingress"; Implementation = @("traefik") } }
                "metrics-server" { $newAddon = [pscustomobject]@{Name = "metrics"} }
                Default { $newAddon = [pscustomobject]@{Name = $addon } }
            }

            Write-Information "Config for addon '$addon' migrated."
        }
        elseif ($addon -is [pscustomobject]) {
            switch ($($addon.Name)) {
                "gateway-nginx" { 
                    $newAddon = [pscustomobject]@{Name = "gateway-api"} 
                    Write-Information "Config for addon '$($addon.Name)' migrated."
                }
                "ingress-nginx" { 
                    $newAddon = [pscustomobject]@{Name = "ingress"; Implementation = "nginx" }
                    Write-Information "Config for addon '$($addon.Name)' migrated."                
                }
                "traefik" { 
                    $newAddon = [pscustomobject]@{Name = "ingress"; Implementation = "traefik" } 
                    Write-Information "Config for addon '$($addon.Name)' migrated."
                }
                "metrics-server" { 
                    $newAddon = [pscustomobject]@{Name = "metrics"} 
                    Write-Information "Config for addon '$($addon.Name)' migrated."
                }
                "smb-share" { 
                    $newAddon = [pscustomobject]@{Name = "storage"; SmbHostType = $addon.SmbHostType } 
                    Write-Information "Config for addon '$($addon.Name)' migrated."
                }
            }
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

    $enabledAddons = [System.Collections.ArrayList]@()

    if ($null -eq $config) {
        Write-Log "[$script::$function] No addons config found"

        return ,$enabledAddons
    }

    Write-Log "[$script::$function] Addons config found"

    $config | ForEach-Object {
        $addon = $_
        Write-Log "[$script::$function] found addon '$($_.Name)'"
        $alreadyExistingAddon = $enabledAddons | Where-Object { $_.Name -eq $addon.Name }
        if ($alreadyExistingAddon) {
            $alreadyExistingAddon.Implementations.Add($addon.Implementation) | Out-Null
            $enabledAddons = $enabledAddons | Where-Object { $_ -ne $addon.Name }
            if ($enableAddons) {
                $enabledAddons.Add($alreadyExistingAddon) | Out-Null
            } else {
                $enabledAddons = [System.Collections.ArrayList]@($enabledAddons)
            }
        } else {
            if ($null -eq $addon.Implementation) {
                $enabledAddons.Add([pscustomobject]@{ Name = $addon.Name }) | Out-Null
            } else {
                $enabledAddons.Add([pscustomobject]@{ Name = $addon.Name; Implementations = [System.Collections.ArrayList]@($addon.Implementation)}) | Out-Null
            }
        }
    }

    return ,$enabledAddons
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

    $filePath = Get-SetupConfigFilePath
    $parsedSetupJson = Get-Content -Raw $filePath | ConvertFrom-Json

    $enabledAddonMemberExists = Get-Member -InputObject $parsedSetupJson -Name $ConfigKey_EnabledAddons -MemberType Properties
    if (!$enabledAddonMemberExists) {
        $parsedSetupJson = $parsedSetupJson | Add-Member -NotePropertyMembers @{EnabledAddons = @() } -PassThru
    }

    $addonAlreadyExists = $parsedSetupJson.EnabledAddons | Where-Object { $_.Name -eq $Addon.Name }
    if ($addonAlreadyExists) {
        if ($null -ne $Addon.Implementation) {
            $implementationAlreadyExists = $parsedSetupJson.EnabledAddons | Where-Object { ($_.Name -eq $Addon.Name) -and ($_.Implementation -eq $Addon.Implementation)}
            if (!$implementationAlreadyExists) {
                $parsedSetupJson.EnabledAddons += $Addon
                $parsedSetupJson | ConvertTo-Json -Depth 100 | Set-Content -Force $filePath -Confirm:$false
            }
        }
    } else {
        $parsedSetupJson.EnabledAddons += $Addon
        $parsedSetupJson | ConvertTo-Json -Depth 100 | Set-Content -Force $filePath -Confirm:$false
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
    Remove-AddonFromSetupJson -Addon -Addon ([pscustomobject] @{Name = 'DummyAddon' })
#>
function Remove-AddonFromSetupJson {
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

    Write-Log "Removing '$($Addon.Name)' from addons config.."

    $filePath = Get-SetupConfigFilePath
    $parsedSetupJson = Get-Content -Raw $filePath | ConvertFrom-Json

    $enabledAddonMemberExists = Get-Member -InputObject $parsedSetupJson -Name $ConfigKey_EnabledAddons -MemberType Properties
    if ($enabledAddonMemberExists) {
        $enabledAddons = $parsedSetupJson.EnabledAddons
        $newEnabledAddons = $enabledAddons

        $addonExists = $enabledAddons | Where-Object { $_.Name -eq $Addon.Name }
        if ($addonExists) {
            if ($null -ne $Addon.Implementation) {
                $implementationExists = $addonExists | Where-Object { $_.Implementation -eq $Addon.Implementation }
                if ($implementationExists) {
                    $newEnabledAddons = @($enabledAddons | Where-Object { $_.Implementation -ne $Addon.Implementation})
                }
            } else {
                $hasImplementationProperty = $addonExists | Where-Object { $null -ne $_.Implementation }
                if (!$hasImplementationProperty) {
                    $newEnabledAddons = @($enabledAddons | Where-Object { $_.Name -ne $Addon.Name })
                } else {
                    throw "More than one implementation of addon '$($Addon.Name)'. Please specify the implementation!"
                }
            }
        }
        
        if ($newEnabledAddons) {
            $parsedSetupJson.EnabledAddons = $newEnabledAddons
        }
        else {
            $parsedSetupJson.PSObject.Properties.Remove($ConfigKey_EnabledAddons)
        }
        $parsedSetupJson | ConvertTo-Json -Depth 100 | Set-Content -Force $filePath -Confirm:$false
    }
}

function Install-DebianPackages {
    param (
        [parameter()]
        [string] $addon,
        [parameter()]
        [string] $implementation = "",
        [parameter()]
        [string[]]$packages
    )

    $dirName = $addon
    if (($implementation -ne "") -and ($implementation -ne $addon)) {
        $dirName += "_$implementation"
    }

    foreach ($package in $packages) {
        if (!(Get-DebianPackageAvailableOffline -addon $addon -implementation $implementation -package $package)) {
            (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "mkdir -p .${dirName}/${package} && cd .${dirName}/${package} && sudo chown -R _apt:root .").Output | Write-Log
            (Invoke-CmdOnControlPlaneViaSSHKey -Retries 2 -Timeout 2 -CmdToExecute "cd .${dirName}/${package} && sudo apt-get download $package" -RepairCmd 'sudo apt --fix-broken install').Output | Write-Log
            (Invoke-CmdOnControlPlaneViaSSHKey `
                -Retries 2 `
                -Timeout 2 `
                -CmdToExecute "cd .${dirName}/${package} && sudo DEBIAN_FRONTEND=noninteractive apt-get --reinstall install -y --no-install-recommends --no-install-suggests --simulate ./${package}*.deb | grep 'Inst ' | cut -d ' ' -f 2 | sort -u | xargs sudo apt-get download" `
                -RepairCmd 'sudo apt --fix-broken install').Output | Write-Log
        }

        Write-Log "Installing $package offline."
        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo dpkg -i .${dirName}/${package}/*.deb 2>&1").Output | Write-Log
    }
}

function Get-DebianPackageAvailableOffline {
    param (
        [parameter()]
        [string] $addon,
        [parameter()]
        [string] $implementation = "",
        [parameter()]
        [string]$package
    )

    $dirName = $addon
    if (($implementation -ne "") -and ($implementation -ne $addon)) {
        $dirName += "_$implementation"
    }

    # TODO: NOTE: DO NOT USE `ExecCmdMaster` here to get the return value.
    ssh.exe -n -o StrictHostKeyChecking=no -i (Get-SSHKeyControlPlane) (Get-ControlPlaneRemoteUser) "[ -d .${dirName}/${package} ]"
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
        [Parameter(Mandatory = $false)]
        [pscustomobject]$Addon = $(throw 'Please specify the addon.')
    )
    if ($Addon -eq $null) {
        throw 'Addon not specified'
    }
    if ($null -eq ($Addon | Get-Member -MemberType Properties -Name 'Name')) {
        throw "Addon does not contain a property with name 'Name'"
    }

    $enabledAddons = Get-AddonsConfig
    foreach ($enabledAddon in $enabledAddons) {
        if ($enabledAddon.Name -eq $Addon.Name) {
            if ($null -eq $Addon.Implementation) {
                return $true
            }

            if ($enabledAddon.Implementation -eq $Addon.Implementation) {
                return $true
            } 

            return $false
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

    # Copy backup and restore addon hooks for cluster upgrade
    # Why only backup and restore script being copied?
    # As remaining scripts(AfterStart,..) will be copied during re-enabling of addon.
    # NOTE!! If we copy earlier then it interferes with installation procedure.
    foreach ($addonConfig in $backupContentRoot.Config) {
        if ($null -eq $addonConfig.Name) {
            Write-Warning "Invalid addon config '$addonConfig' found, skipping it."
            continue
        }

        $root = Get-ScriptRoot
        $addonHookPath = "$root\$($addonConfig.Name)\hooks"
        if ((Test-Path $addonHookPath) -ne $true) {
            Write-Warning "Addon '$($addonConfig.Name)' no hooks found under $addonHookPath, skipping it."
            continue
        }

        Copy-ScriptsToHooksDir -ScriptPaths @(Get-ChildItem -Path "$addonHookPath" | Where-Object { $_.Name -match "BackUp|Restore" } | ForEach-Object { $_.FullName })
    }

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

    $isEnabled = Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = $Name })

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

function Add-HostEntries {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Url = $(throw 'Url not specified')
    )
    Write-Log "Adding host entry for '$Url'.." -Console

    # add in control plane
    $hostEntry = "$(Get-ConfiguredIPControlPlane) $Url"
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "grep -qxF `'$hostEntry`' /etc/hosts || echo $hostEntry | sudo tee -a /etc/hosts").Output | Write-Log

    $hostFile = 'C:\Windows\System32\drivers\etc\hosts'

    # add in additional worker nodes
    $setupInfo = Get-SetupInfo
    if ($setupInfo.Name -eq 'MultiVMK8s' -and $setupInfo.LinuxOnly -ne $true) {
        $session = Open-RemoteSessionViaSSHKey (Get-DefaultWinVMName) (Get-DefaultWinVMKey)

        Invoke-Command -Session $session {
            Set-Location "$env:SystemDrive\k"
            Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

            if (!$(Get-Content $using:hostFile | ForEach-Object { $_ -match $using:hostEntry }).Contains($true)) {
                Add-Content $using:hostFile $using:hostEntry
            }
        }
    }

    # add in host
    if (!$(Get-Content $hostFile | ForEach-Object { $_ -match $hostEntry }).Contains($true)) {
        Add-Content $hostFile $hostEntry
    }
}

function Update-IngressForAddons {
    param (
        [Parameter(Mandatory = $true)]
        [string]
        $Enable
    )
    Write-Log "Adapting ingress entries for addons, security is on: $Enable" -Console

    # check ingress type
    if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'ingress'; Implementation = 'nginx' })) -eq $false) {
        Write-Log 'Traefik ingress is used, adaptions cannot be made for traefik, please use nginx!' -Console
        return
    }

    # TODO: this implementation needs to be adapted to be more generic in next version
    $addons = Get-EnabledAddons
    $addons.Addons | ForEach-Object {
        $addon = $_
        $addonConfig = Get-AddonConfig -Name $addon
        if ($null -eq $addonConfig) {
            Write-Log "Addon '$addon' not found in config, skipping.." -Console
            return
        }

        # addon dashboard
        $name = 'dashboard'
        if ($addon -eq $name -and $Enable -eq $true) {
            Write-Log "Security addon enabled: adapting $name addon ..." -Console
            (Invoke-Kubectl -Params 'delete' , '-f', "$PSScriptRoot\dashboard\manifests\dashboard-nginx-ingress.yaml").Output | Write-Log
            (Invoke-Kubectl -Params 'apply' , '-f', "$PSScriptRoot\security\addons\dashboard-nginx-ingress-security.yaml").Output | Write-Log
            return
        }
        if ($addon -eq $name -and $Enable -eq $false) {
            Write-Log "Security addon disable: adapting $name addon ..." -Console
            (Invoke-Kubectl -Params 'delete' , '-f', "$PSScriptRoot\security\addons\dashboard-nginx-ingress-security.yaml").Output | Write-Log
            (Invoke-Kubectl -Params 'apply' , '-f', "$PSScriptRoot\dashboard\manifests\dashboard-nginx-ingress.yaml").Output | Write-Log
            return
        }

        # addon logging
        $name = 'logging'
        if ($addon -eq $name -and $Enable -eq $true) {
            Write-Log "Security addon enabled: adapting $name addon ..." -Console
            (Invoke-Kubectl -Params 'delete' , '-f', "$PSScriptRoot\logging\manifests\opensearch-dashboards\ingress.yaml").Output | Write-Log
            (Invoke-Kubectl -Params 'apply' , '-f', "$PSScriptRoot\security\addons\logging-nginx-ingress-security.yaml").Output | Write-Log
            return
        }
        if ($addon -eq $name -and $Enable -eq $false) {
            Write-Log "Security addon disable: adapting $name addon ..." -Console
            (Invoke-Kubectl -Params 'delete' , '-f', "$PSScriptRoot\security\addons\logging-nginx-ingress-security.yaml").Output | Write-Log
            (Invoke-Kubectl -Params 'apply' , '-f', "$PSScriptRoot\logging\manifests\opensearch-dashboards\ingress.yaml").Output | Write-Log
            return
        }

        # addon monitoring
        $name = 'monitoring'
        if ($addon -eq $name -and $Enable -eq $true) {
            Write-Log "Security addon enabled: adapting $name addon ..." -Console
            (Invoke-Kubectl -Params 'delete' , '-f', "$PSScriptRoot\monitoring\manifests\plutono\ingress.yaml").Output | Write-Log
            (Invoke-Kubectl -Params 'delete' , '-f', "$PSScriptRoot\monitoring\manifests\plutono\configmap.yaml").Output | Write-Log
            (Invoke-Kubectl -Params 'apply' , '-f', "$PSScriptRoot\security\addons\monitoring-nginx-ingress-security.yaml").Output | Write-Log
            (Invoke-Kubectl -Params 'apply' , '-f', "$PSScriptRoot\security\addons\monitoring-configmap-plutono-security.yaml").Output | Write-Log
            # restart pod plutono
            (Invoke-Kubectl -Params 'delete' , 'pod', '-l', 'app.kubernetes.io/name=kube-prometheus-stack-plutono', '-n', 'monitoring').Output | Write-Log
            return
        }
        if ($addon -eq $name -and $Enable -eq $false) {
            Write-Log "Security addon disable: adapting $name addon ..." -Console
            (Invoke-Kubectl -Params 'delete' , '-f', "$PSScriptRoot\security\addons\monitoring-nginx-ingress-security.yaml").Output | Write-Log
            (Invoke-Kubectl -Params 'delete' , '-f', "$PSScriptRoot\security\addons\monitoring-configmap-plutono-security.yaml").Output | Write-Log
            (Invoke-Kubectl -Params 'apply' , '-f', "$PSScriptRoot\monitoring\manifests\plutono\ingress.yaml").Output | Write-Log
            (Invoke-Kubectl -Params 'apply' , '-f', "$PSScriptRoot\monitoring\manifests\plutono\configmap.yaml").Output | Write-Log
            # restart pod plutono
            (Invoke-Kubectl -Params 'delete' , 'pod', '-l', 'app.kubernetes.io/name=kube-prometheus-stack-plutono', '-n', 'monitoring').Output | Write-Log
            return
        }
    }
    Write-Log 'Addons have been adapted to new security settings' -Console
}

Export-ModuleMember -Function Get-EnabledAddons, Add-AddonToSetupJson, Remove-AddonFromSetupJson,
Install-DebianPackages, Get-DebianPackageAvailableOffline, Test-IsAddonEnabled, Invoke-AddonsHooks, Copy-ScriptsToHooksDir,
Remove-ScriptsFromHooksDir, Get-AddonConfig, Backup-Addons, Restore-Addons, Get-AddonStatus, Find-AddonManifests,
Get-ErrCodeAddonAlreadyDisabled, Get-ErrCodeAddonAlreadyEnabled, Get-ErrCodeAddonEnableFailed, Get-ErrCodeAddonNotFound,
Add-HostEntries, Update-IngressForAddons