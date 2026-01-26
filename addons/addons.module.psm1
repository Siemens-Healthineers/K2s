# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

$infraModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
$nodeModule = "$PSScriptRoot/../lib/modules/k2s/k2s.node.module/k2s.node.module.psm1"

Import-Module $infraModule, $clusterModule, $nodeModule

$ConfigKey_EnabledAddons = 'EnabledAddons'
$hooksDir = "$PSScriptRoot\hooks"
$backupFileName = 'backup_addons.json'
$cmctlExe = "$(Get-KubeBinPath)\cmctl.exe"

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
	return (Get-ConfigValue -Path (Get-SetupConfigFilePath) -Key $ConfigKey_EnabledAddons)
}

function Get-ScriptRoot {
	return $PSScriptRoot
}

function Enable-AddonFromConfig {
	param (
		[Parameter(Mandatory = $false)]
		[pscustomobject]$Config = $(throw 'Config object not specified'),
		[Parameter(Mandatory = $false)]
		[string] $Root = $null
	)
	if ($null -eq $Config.Name) {
		Write-Warning "Invalid addon config '$Config' found, skipping it."
		return
	}
	# Check if root is null or empty and assign Get-ScriptRoot if so
	if ([string]::IsNullOrEmpty($Root)) {
		$Root = Get-ScriptRoot
	}

	$dirName = $Config.Name
	$addonName = $Config.Name
	if ($null -ne $Config.Implementation) {
		$dirName += "\$($Config.Implementation)"
		$addonName += " $($Config.Implementation)"
	}

	$enableCmdPath = "$Root\$dirName\Enable.ps1"

	if ((Test-Path $enableCmdPath) -ne $true) {
		Write-Warning "Addon '$($Config.Name)' seems to be deprecated, skipping it."
		return
	}

	Write-Log "Re-enabling addon '$addonName'.."

	& $enableCmdPath 

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
				'gateway-nginx' { $newAddon = [pscustomobject]@{Name = 'gateway-api' } }
				'ingress-nginx' { $newAddon = [pscustomobject]@{Name = 'ingress'; Implementation = @('nginx') } }
				'traefik' { $newAddon = [pscustomobject]@{Name = 'ingress'; Implementation = @('traefik') } }
				'metrics-server' { $newAddon = [pscustomobject]@{Name = 'metrics' } }
				Default { $newAddon = [pscustomobject]@{Name = $addon } }
			}

			Write-Information "Config for addon '$addon' migrated."
		}
		elseif ($addon -is [pscustomobject]) {
			switch ($($addon.Name)) {
				'gateway-nginx' { 
					$newAddon = [pscustomobject]@{Name = 'gateway-api' } 
					Write-Information "Config for addon '$($addon.Name)' migrated."
				}
				'ingress-nginx' { 
					$newAddon = [pscustomobject]@{Name = 'ingress'; Implementation = 'nginx' }
					Write-Information "Config for addon '$($addon.Name)' migrated."                
				}
				'traefik' { 
					$newAddon = [pscustomobject]@{Name = 'ingress'; Implementation = 'traefik' } 
					Write-Information "Config for addon '$($addon.Name)' migrated."
				}
				'metrics-server' { 
					$newAddon = [pscustomobject]@{Name = 'metrics' } 
					Write-Information "Config for addon '$($addon.Name)' migrated."
				}
				'smb-share' { 
					$newAddon = [pscustomobject]@{Name = 'storage'; SmbHostType = $addon.SmbHostType } 
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

	Write-Log 'Getting enabled addons..'

	$config = Get-AddonsConfig

	$enabledAddons = [System.Collections.ArrayList]@()

	if ($null -eq $config) {
		Write-Log 'No addons config found'

		return , $enabledAddons
	}

	Write-Log 'Addons config found'

	$config | ForEach-Object {
		$addon = $_
		Write-Log "found addon '$($_.Name)'"
		$alreadyExistingAddon = $enabledAddons | Where-Object { $_.Name -eq $addon.Name }
		if ($alreadyExistingAddon) {
			$alreadyExistingAddon.Implementations.Add($addon.Implementation) | Out-Null
			$enabledAddons = $enabledAddons | Where-Object { $_ -ne $addon.Name }
			if ($enableAddons) {
				$enabledAddons.Add($alreadyExistingAddon) | Out-Null
			}
			else {
				$enabledAddons = [System.Collections.ArrayList]@($enabledAddons)
			}
		}
		else {
			if ($null -eq $addon.Implementation) {
				$enabledAddons.Add([pscustomobject]@{ Name = $addon.Name }) | Out-Null
			}
			else {
				$enabledAddons.Add([pscustomobject]@{ Name = $addon.Name; Implementations = [System.Collections.ArrayList]@($addon.Implementation) }) | Out-Null
			}
		}
	}

	return , $enabledAddons
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
			$implementationAlreadyExists = $parsedSetupJson.EnabledAddons | Where-Object { ($_.Name -eq $Addon.Name) -and ($_.Implementation -eq $Addon.Implementation) }
			if (!$implementationAlreadyExists) {
				$parsedSetupJson.EnabledAddons += $Addon
				$parsedSetupJson | ConvertTo-Json -Depth 100 | Set-Content -Force $filePath -Confirm:$false
			}
		}
	}
	else {
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

	$addonsMember = Get-Member -InputObject $parsedSetupJson -Name $ConfigKey_EnabledAddons -MemberType Properties
	if ($null -eq $addonsMember) {
		Write-Log 'No addons config found, skipping'
		return
	}

	$enabledAddons = $parsedSetupJson.EnabledAddons
	$newEnabledAddons = $enabledAddons

	$addonExists = $enabledAddons | Where-Object { $_.Name -eq $Addon.Name }
	if ($addonExists) {
		if ($null -ne $Addon.Implementation) {
			$implementationExists = $addonExists | Where-Object { $_.Implementation -eq $Addon.Implementation }
			if ($implementationExists) {
				$newEnabledAddons = @($enabledAddons | Where-Object { $_.Implementation -ne $Addon.Implementation })
			}
		}
		else {
			$hasImplementationProperty = $addonExists | Where-Object { $null -ne $_.Implementation }
			if (!$hasImplementationProperty) {
				$newEnabledAddons = @($enabledAddons | Where-Object { $_.Name -ne $Addon.Name })
			}
			else {
				throw "More than one implementation of addon '$($Addon.Name)'. Please specify the implementation!"
			}
		}
	}
	else {
		if ($null -ne $Addon.Implementation) {
			$name += " $($Addon.Implementation)"
		}
		Write-Log "Addon '$name' not found in addons config, skipping"
	}
		
	if ($newEnabledAddons) {
		$parsedSetupJson.EnabledAddons = $newEnabledAddons
	}
	else {
		$parsedSetupJson.PSObject.Properties.Remove($ConfigKey_EnabledAddons)
	}
	$parsedSetupJson | ConvertTo-Json -Depth 100 | Set-Content -Force $filePath -Confirm:$false
}

function Install-DebianPackages {
	param (
		[parameter()]
		[string] $addon,
		[parameter()]
		[string] $implementation = '',
		[parameter()]
		[string[]]$packages
	)

	$dirName = $addon
	if (($implementation -ne '') -and ($implementation -ne $addon)) {
		$dirName += "_$implementation"
	}

	foreach ($package in $packages) {
		if (!(Get-DebianPackageAvailableOffline -addon $addon -implementation $implementation -package $package)) {
			(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "mkdir -p .${dirName}/${package} && cd .${dirName}/${package} && sudo chown -R _apt:root .").Output | Write-Log
			(Invoke-CmdOnControlPlaneViaSSHKey -Retries 2 -Timeout 2 -CmdToExecute "cd .${dirName}/${package} && sudo apt-get download $package" -RepairCmd 'sudo dpkg --configure -a; sudo apt --fix-broken install').Output | Write-Log
			(Invoke-CmdOnControlPlaneViaSSHKey `
				-Retries 2 `
				-Timeout 2 `
				-CmdToExecute "cd .${dirName}/${package} && sudo DEBIAN_FRONTEND=noninteractive apt-get --reinstall install -y --no-install-recommends --no-install-suggests --simulate ./${package}*.deb | grep 'Inst ' | cut -d ' ' -f 2 | sort -u | xargs sudo apt-get download" `
				-RepairCmd 'sudo dpkg --configure -a; sudo apt --fix-broken install').Output | Write-Log
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
		[string] $implementation = '',
		[parameter()]
		[string]$package
	)

	$dirName = $addon
	if (($implementation -ne '') -and ($implementation -ne $addon)) {
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
		[ValidateSet('AfterStart', 'BeforeUninstall', 'AfterUninstall')]
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

		Copy-ScriptsToHooksDir -ScriptPaths @(Get-ChildItem -Path "$addonHookPath" | Where-Object { $_.Name -match 'BackUp|Restore' } | ForEach-Object { $_.FullName })
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
		[string]$BackupDir = $(throw 'Please specify the back-up directory.'),
		[Parameter(Mandatory = $false, HelpMessage = 'Specifies whether to restore the addons or avoid it.')]
		[switch] $AvoidRestore,
		[Parameter(Mandatory = $false)]
		[string] $Root = $null
	)
	Write-Log 'Restoring addons..'

	$backupFilePath = (Join-Path $BackupDir $backupFileName)

	if ((Test-Path $backupFilePath) -ne $true) {
		Write-Log 'Addons config file back-up not found, skipping.'
		return
	}

	$backupContentRoot = Get-Content $backupFilePath -Raw | ConvertFrom-Json
	   
	# Conditionally invoke Invoke-BackupRestoreHooks based on the AvoidRestore parameter
	if ($AvoidRestore -eq $false) {
		foreach ($addonConfig in $backupContentRoot.Config) {
			Enable-AddonFromConfig -Config $addonConfig
		}
		Write-Log 'Restoring addons data..'
		Invoke-BackupRestoreHooks -HookType Restore -BackupDir $BackupDir
	}
	else {
		foreach ($addonConfig in $backupContentRoot.Config) {
			Enable-AddonFromConfig -Config $addonConfig -Root $Root
		}
		Write-Log 'Skipping restoring addons data.'
	}

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

function Get-ErrCodeInvalidParameter { 'addon-invalid-parameter' }

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

	# add in host
	if (!$(Get-Content $hostFile | ForEach-Object { $_ -match $hostEntry }).Contains($true)) {
		Add-Content $hostFile $hostEntry
	}
}

function Update-Addons {
	param (
		[Parameter(Mandatory = $false)]
		[string]
		$AddonName = $(throw 'Addon name not specified')
	)
	Write-Log "Adapting addons called from addon '$AddonName'" -Console

	$addons = Get-AddonsConfig

	if ($null -eq $addons) {
		Write-Log 'No addons to adapt, skipping' -Console
		return
	}

	$addons | ForEach-Object {
		# Not for addons with the name from input
		if ($_.Name -ne $AddonName) {
			$addon = $_.Name
			$addonConfig = Get-AddonConfig -Name $addon
			if ($null -eq $addonConfig) {
				Write-Log "Addon '$($addon.Name)' not found in config, skipping.." -Console
				return
			}

			$props = Get-AddonProperties -Addon ([pscustomobject] @{ Name = $addonConfig.Name; Implementation = $addonConfig.Implementation })

			if (Test-Path -Path "$PSScriptRoot\$($props.Directory)\Update.ps1") {
				&"$PSScriptRoot\$($props.Directory)\Update.ps1"
			}
		}
	}
	Write-Log 'Addons have been adapted' -Console
}

function Get-AddonProperties {
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

	$addonName = $Addon.Name
	$directory = $Addon.Name
	if ($null -ne $Addon.Implementation) {
		$addonName += " $($Addon.Implementation)"
		$directory += "\$($Addon.Implementation)"
	}

	return [pscustomobject]@{Name = $addonName; Directory = $directory }
}

<#
.DESCRIPTION
Updates the ingress manifest for an addon based on the ingress controller detected in the cluster.
#>
function Update-IngressForAddon {
	param (
		[Parameter(Mandatory = $false)]
		[pscustomobject]$Addon = $(throw 'Please specify the addon.')
	)

	if (Test-NginxIngressControllerAvailability) {
		Remove-IngressForTraefik -Addon $Addon
		Remove-IngressForNginxGateway -Addon $Addon
		Update-IngressForNginx -Addon $Addon
	}
	elseif (Test-TraefikIngressControllerAvailability) {
		Remove-IngressForNginx -Addon $Addon
		Remove-IngressForNginxGateway -Addon $Addon
		Update-IngressForTraefik -Addon $Addon
	}
	elseif( Test-NginxGatewayAvailability) {
		Remove-IngressForTraefik -Addon $Addon
		Remove-IngressForNginx -Addon $Addon
		Update-IngressForNginxGateway -Addon $Addon
	}
	else {
		Remove-IngressForNginx -Addon $Addon
		Remove-IngressForTraefik -Addon $Addon
		Remove-IngressForNginxGateway -Addon $Addon
	}
}

<#
.DESCRIPTION
Determines if Nginx ingress controller is deployed in the cluster
#>
function Test-NginxIngressControllerAvailability {
	$existingServices = (Invoke-Kubectl -Params 'get', 'service', '-n', 'ingress-nginx', '-o', 'yaml').Output 
	if ("$existingServices" -match '.*ingress-nginx-controller.*') {
		return $true
	}
	return $false
}

<#
.DESCRIPTION
Determines if Traefik ingress controller is deployed in the cluster
#>
function Test-TraefikIngressControllerAvailability {
	$existingServices = (Invoke-Kubectl -Params 'get', 'service', '-n', 'ingress-traefik', '-o', 'yaml').Output
	if ("$existingServices" -match '.*traefik.*') {
		return $true
	}
	return $false
}

<#
.DESCRIPTION
Determines if Nginx gateway controller is deployed in the cluster
#>
function Test-NginxGatewayAvailability {
	$existingServices = (Invoke-Kubectl -Params 'get', 'service', '-n', 'nginx-gw', '-o', 'yaml').Output
	if ("$existingServices" -match '.*nginx.*') {
		return $true
	}
	return $false
}

<#
.DESCRIPTION
Determines if KeyCloak is deployed in the cluster
#>
function Test-KeyCloakServiceAvailability {
	$existingServices = (Invoke-Kubectl -Params 'get', 'service', '-n', 'security', '-o', 'yaml').Output
	if ("$existingServices" -match '.*keycloak.*') {
		return $true
	}
	return $false
}

<#
.DESCRIPTION
Determines if linkerd service is deployed in the cluster
#>
function Test-LinkerdServiceAvailability {
	$existingServices = (Invoke-Kubectl -Params 'get', 'service', '-n', 'linkerd', '-o', 'yaml').Output
	if ("$existingServices" -match '.*linkerd.*') {
		return $true
	}
	return $false
}

<#
.DESCRIPTION
Determines if trust manager service is deployed in the cluster
#>
function Test-TrustManagerServiceAvailability {
	$existingServices = (Invoke-Kubectl -Params 'get', 'service', '-n', 'cert-manager', '-o', 'yaml').Output
	if ("$existingServices" -match '.*trust-manager*') {
		return $true
	}
	return $false
}

<#
.DESCRIPTION
Determines if keycloak service is deployed in the cluster
#>
function Test-KeyCloakServiceAvailability {
	$existingServices = (Invoke-Kubectl -Params 'get', 'service', '-n', 'security', '-o', 'yaml').Output
	if ("$existingServices" -match '.*keycloak*') {
		return $true
	}
	return $false
}

<#
.DESCRIPTION
Enables a ingress addon based on the input
#>
function Enable-IngressAddon([string]$Ingress) {
	switch ($Ingress) {
		'nginx' {
			&"$PSScriptRoot\ingress\nginx\Enable.ps1"
			break
		}
		'nginx-gw' {
			&"$PSScriptRoot\ingress\nginx-gw\Enable.ps1"
			break
		}
		'traefik' {
			&"$PSScriptRoot\ingress\traefik\Enable.ps1"
			break
		}
	}
}

<#
.DESCRIPTION
Gets the location of traefik ingress yaml
#>
function Get-IngressTraefikConfig {
	param (
		[Parameter(Mandatory = $false)]
		[string]$Directory = $(throw 'Directory of the ingress traefik config')
	)
	return "$PSScriptRoot\$Directory\manifests\ingress-traefik"
}

<#
.DESCRIPTION
Gets the location of nginx ingress yaml
#>
function Get-IngressNginxConfigDirectory {
	param (
		[Parameter(Mandatory = $false)]
		[string]$Directory = $(throw 'Directory of the ingress nginx config')
	)
	return "$PSScriptRoot\$Directory\manifests\ingress-nginx"
}

<#
.DESCRIPTION
Gets the location of nginx ingress gateway yaml
#>
function Get-IngressNginxGatewayConfig {
	return 'ingress-nginx-gw'
}


<#
.DESCRIPTION
Gets the location of nginx secure ingress yaml
#>
function Get-IngressNginxGatewaySecureConfig {
	return 'ingress-nginx-gw-secure'
}

<#
.DESCRIPTION
Gets the location of nginx secure ingress yaml
#>
function Get-IngressNginxSecureConfig {
	param (
		[Parameter(Mandatory = $false)]
		[string]$Directory = $(throw 'Directory of the ingress nginx secure config')
	)
	return "$PSScriptRoot\$Directory\manifests\ingress-nginx-secure"
}

function Test-HydraAvailability {
	$existingDeployments = (Invoke-Kubectl -Params 'get', 'deployment', '-n', 'security', '-o', 'yaml').Output
	if ("$existingDeployments" -match '.*hydra.*') {
		return $true
	}
	return $false
}

<#
.DESCRIPTION
Deploys the addon's ingress manifest for Nginx ingress controller
#>
function Update-IngressForNginx {
	param (
		[Parameter(Mandatory = $false)]
		[pscustomobject]$Addon = $(throw 'Please specify the addon.')
	)
	$props = Get-AddonProperties -Addon $Addon
	$kustomizationDir = ''

	# Store each result separately for debugging
	$keycloakAvailable = Test-KeyCloakServiceAvailability
	Write-Log "KeyCloak available: $keycloakAvailable" -Console
	
	# Always evaluate Hydra availability
	$hydraAvailable = Test-HydraAvailability
	Write-Log "Hydra available: $hydraAvailable" -Console

	if ($keycloakAvailable -or $hydraAvailable) {
		Write-Log "  Applying secure nginx ingress manifest for $($props.Name)..." -Console
		$kustomizationDir = Get-IngressNginxSecureConfig -Directory $props.Directory
		# check if $kustomizationDir does not exist
		if (!(Test-Path -Path $kustomizationDir)) {
			Write-Log "  Applying nginx ingress manifest for $($props.Name) $($props.Directory)..." -Console
			$kustomizationDir = Get-IngressNginxConfigDirectory -Directory $props.Directory
		}
	}
	else {
		Write-Log "  Applying nginx ingress manifest for $($props.Name) $($props.Directory)..." -Console
		$kustomizationDir = Get-IngressNginxConfigDirectory -Directory $props.Directory
	}
	Write-Log "   Apply in cluster folder: $($kustomizationDir)" -Console
	Invoke-Kubectl -Params 'apply', '-k', $kustomizationDir 
}

<#
.DESCRIPTION
Delete the addon's ingress manifest for Nginx ingress controller
#>
function Remove-IngressForNginx {
	param (
		[Parameter(Mandatory = $false)]
		[pscustomobject]$Addon = $(throw 'Please specify the addon.')
	)

	$props = Get-AddonProperties -Addon $Addon
	
	Write-Log "  Deleting nginx ingress manifest for $($props.Name)..." -Console
	# SecureNginxConfig is a superset of NginsConfig, so we delete that:
	$kustomizationDir = Get-IngressNginxSecureConfig -Directory $props.Directory
	Invoke-Kubectl -Params 'delete', '-k', $kustomizationDir | Out-Null
}

<#
.DESCRIPTION
Deploys the addon's ingress manifest for Traefik ingress controller
#>
function Update-IngressForTraefik {
	param (
		[Parameter(Mandatory = $false)]
		[pscustomobject]$Addon = $(throw 'Please specify the addon.')
	)

	$props = Get-AddonProperties -Addon $Addon
	$kustomizationDir = ''

	# Store each result separately for debugging
	$keycloakAvailable = Test-KeyCloakServiceAvailability
	Write-Log "KeyCloak available: $keycloakAvailable" -Console
	
	# Always evaluate Hydra availability
	$hydraAvailable = Test-HydraAvailability
	Write-Log "Hydra available: $hydraAvailable" -Console

	if ($keycloakAvailable -or $hydraAvailable) {
		Write-Log "  Applying secure nginx ingress manifest for $($props.Name)..." -Console
		$kustomizationDir = Get-IngressTraefikSecureConfig -Directory $props.Directory
		# check if $kustomizationDir does not exist
		if (!(Test-Path -Path $kustomizationDir)) {
			Write-Log "  Applying nginx ingress manifest for $($props.Name) $($props.Directory)..." -Console
			$kustomizationDir = Get-IngressTraefikConfig -Directory $props.Directory
		}
	}
	else {
		Write-Log "  Applying nginx ingress manifest for $($props.Name) $($props.Directory)..." -Console
		$kustomizationDir = Get-IngressTraefikConfig -Directory $props.Directory
	}

	Write-Log "   Apply in cluster folder: $($kustomizationDir)" -Console
	Invoke-Kubectl -Params 'apply', '-k', $kustomizationDir | Out-Null
}

<#
.DESCRIPTION
Delete the addon's ingress manifest for Traefik ingress controller
#>
function Remove-IngressForTraefik {
	param (
		[Parameter(Mandatory = $false)]
		[pscustomobject]$Addon = $(throw 'Please specify the addon.')
	)

	$props = Get-AddonProperties -Addon $Addon

	Write-Log "  Deleting traefik ingress manifest for $($props.Name)..." -Console
	$ingressTraefikConfig = Get-IngressTraefikConfig -Directory $props.Directory
	
	Invoke-Kubectl -Params 'delete', '-k', $ingressTraefikConfig | Out-Null

	$kustomizationDir = Get-IngressTraefikSecureConfig -Directory $props.Directory
	if (!(Test-Path -Path $kustomizationDir)) {
		Write-Log "  Applying nginx ingress manifest for $($props.Name) $($props.Directory)..." -Console
		$kustomizationDir = Get-IngressTraefikConfig -Directory $props.Directory
	}
	Invoke-Kubectl -Params 'delete', '-k', $kustomizationDir | Out-Null
}

<#
.DESCRIPTION
Deploys the addon's ingress manifest for ingress nginx gateway controller
#>
function Update-IngressForNginxGateway {
	param (
		[Parameter(Mandatory = $false)]
		[pscustomobject]$Addon = $(throw 'Please specify the addon.')
	)

	$props = Get-AddonProperties -Addon $Addon
	$kustomizationDir = ''

	#Store each result separately for debugging
	$keycloakAvailable = Test-KeyCloakServiceAvailability
	Write-Log "KeyCloak available: $keycloakAvailable" -Console
	
	# Always evaluate Hydra availability
	$hydraAvailable = Test-HydraAvailability
	Write-Log "Hydra available: $hydraAvailable" -Console

	if ($keycloakAvailable -or $hydraAvailable) {
		Write-Log "  Applying secure nginx ingress gateway manifest for $($props.Name)..." -Console
		$ingressDir = Get-IngressNginxGatewaySecureConfig
		$kustomizationDir = "$PSScriptRoot\$($props.Directory)\manifests\$ingressDir"
		# check if $kustomizationDir does not exist
		if (!(Test-Path -Path $kustomizationDir)) {
			Write-Log "  Applying nginx ingress gateway manifest for $($props.Name) $($props.Directory)..." -Console
			$ingressDir = Get-IngressNginxGatewayConfig
			$kustomizationDir = "$PSScriptRoot\$($props.Directory)\manifests\$ingressDir"
		}
	}
	else {
		Write-Log "  Applying nginx ingress gateway manifest for $($props.Name) $($props.Directory)..." -Console
		$ingressDir = Get-IngressNginxGatewayConfig
		$kustomizationDir = "$PSScriptRoot\$($props.Directory)\manifests\$ingressDir"
	}

	Write-Log "   Apply in cluster folder: $($kustomizationDir)" -Console
	Invoke-Kubectl -Params 'apply', '-k', $kustomizationDir | Out-Null
}

<#
.DESCRIPTION
Delete the addon's ingress manifest for Gateway fabric controller
#>
function Remove-IngressForNginxGateway {
	param (
		[Parameter(Mandatory = $false)]
		[pscustomobject]$Addon = $(throw 'Please specify the addon.')
	)

	$props = Get-AddonProperties -Addon $Addon

	Write-Log "  Deleting gateway manifest for $($props.Name)..." -Console
	$nginxGatewayConfig = Get-IngressNginxGatewayConfig -Directory $props.Directory
	
	Invoke-Kubectl -Params 'delete', '-k', $nginxGatewayConfig | Out-Null

	$kustomizationDir = Get-IngressNginxGatewaySecureConfig -Directory $props.Directory
	if (!(Test-Path -Path $kustomizationDir)) {
		Write-Log "  Applying nginx ingress manifest for $($props.Name) $($props.Directory)..." -Console
		$kustomizationDir = Get-IngressNginxGatewaySecureConfig -Directory $props.Directory
	}
	Invoke-Kubectl -Params 'delete', '-k', $kustomizationDir | Out-Null
}

<#
.DESCRIPTION
Enables a storage addon based on the input
#>
function Enable-StorageAddon([string]$Storage) {
	switch ($Storage) {
		'smb' {
			&"$PSScriptRoot\storage\smb\Enable.ps1"
			break
		}
	}
}

function Get-AddonNameFromFolderPath {
	param (
		[string]$BaseFolderPath
	)

	# Split the path into an array of folder names
	$pathParts = $BaseFolderPath -split '\\'

	# Find the index of the 'addons' folder
	$addonsIndex = $pathParts.IndexOf('addons')

	# Check if 'addons' is found and there is a next folder
	if ($addonsIndex -ne -1 -and $addonsIndex -lt ($pathParts.Length - 1)) {
		# Return the next folder name after 'addons'
		return $pathParts[$addonsIndex + 1]
	}
	else {
		Write-Error "'addons' folder not found or no folder after 'addons'."
		return $null
	}
}

<#
.DESCRIPTION
Gets the location of traefik secure ingress yaml
#>
function Get-IngressTraefikSecureConfig {
	param (
		[Parameter(Mandatory = $false)]
		[string]$Directory = $(throw 'Directory of the ingress traefik secure config')
	)
	return "$PSScriptRoot\$Directory\manifests\ingress-traefik-secure"
}

function Write-BrowserWarningForUser {
	@'
Be aware: Browsers keep track on several security-related properties of web sites.
If you cannot access your site, then please delete the HSTS settings for your site (e.g. 'k2s.cluster.local')
here: chrome://net-internals/#hsts (works in Chrome and Edge) and try again.
  
'@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
}

<#
.DESCRIPTION
Extracts container images from YAML files referenced in additionalImagesFiles
#>
function Get-ImagesFromYamlFiles {
    param(
        [string[]]$YamlFiles,
        [string]$BaseDirectory
    )
    
    $allImages = @()
    
    foreach ($yamlFile in $YamlFiles) {
        if ([System.IO.Path]::IsPathRooted($yamlFile)) {
            $filePath = $yamlFile
        } else {
            $filePath = Join-Path $BaseDirectory $yamlFile
            $filePath = [System.IO.Path]::GetFullPath($filePath)
        }
        
        if (Test-Path $filePath) {
            Write-Log "Extracting images from $filePath"
            try {
                $content = Get-Content -Path $filePath -Raw
                $allImages += Get-ImagesFromYaml -YamlContent $content
            }
            catch {
                Write-Log "Warning: Failed to parse YAML file $filePath`: $($_.Exception.Message)"
            }
        } else {
            Write-Log "Warning: YAML file not found: $filePath"
        }
    }
    
    return $allImages | Select-Object -Unique | Where-Object { $_ -ne '' }
}

<#
.DESCRIPTION
Extracts container images from YAML content using pattern matching
#>
function Get-ImagesFromYaml {
    param([string]$YamlContent)
    
    $images = @()
    $lines = $YamlContent -split "`n"
    
    foreach ($line in $lines) {
        if ($line -match '^\s*image:\s*(.+)$') {
            $imageValue = ($matches[1] -split '#')[0].Trim().Trim('"').Trim("'")
            if ($imageValue -ne '') { $images += $imageValue }
        } elseif ($line -match '--[a-zA-Z-]+=([a-zA-Z0-9\.\-_/]+/[a-zA-Z0-9\.\-_/]+:[a-zA-Z0-9\.\-_]+)') {
            $imageValue = $matches[1].Trim()
            if ($imageValue -ne '' -and $imageValue.Contains('/') -and $imageValue.Contains(':')) { $images += $imageValue }
        }
    }
    
    return $images
}

<#
.DESCRIPTION
Removes versionless images when versioned equivalents exist
#>
function Remove-VersionlessImages {
    param([string[]]$Images)
    
    if (-not $Images) { return @() }
    
    $versioned = @{}
    $result = @()
    
    foreach ($image in $Images) {
        if ($image -match '^(.+):(.+)$' -and $matches[2].Trim()) {
            $versioned[$matches[1]] = $image
        }
    }
    
    foreach ($image in $Images) {
        if ($image -match '^(.+):(.+)$' -and $matches[2].Trim()) {
            if ($result -notcontains $image) { $result += $image }
        } elseif (-not $versioned.ContainsKey($image)) {
            if ($result -notcontains $image) { $result += $image }
        } else {
            Write-Log "Skipping versionless '$image' - using versioned '$($versioned[$image])'"
        }
    }
    
    return $result
}

<#
.SYNOPSIS
Gets the path to cert-manager manifest file.
.DESCRIPTION
Returns the absolute path to the cert-manager YAML manifest in the common addon folder.
#>
function Get-CertManagerConfig {
    return "$PSScriptRoot\common\manifests\certmanager\cert-manager.yaml"
}

<#
.SYNOPSIS
Gets the path to CA ClusterIssuer manifest file.
.DESCRIPTION
Returns the absolute path to the CA ClusterIssuer YAML manifest in the common addon folder.
#>
function Get-CAIssuerConfig {
    return "$PSScriptRoot\common\manifests\certmanager\ca-issuer.yaml"
}

<#
.SYNOPSIS
Downloads cmctl.exe CLI tool for cert-manager.
.DESCRIPTION
Downloads the cmctl.exe binary from the URL specified in addon.manifest.yaml.
Skips download if file already exists.
.PARAMETER ManifestPath
Path to the addon manifest YAML file containing download specifications.
.PARAMETER K2sRoot
Root directory of the K2s installation.
.PARAMETER Proxy
Optional proxy server to use for download.
#>
function Install-CmctlCli {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ManifestPath,
        
        [Parameter(Mandatory = $true)]
        [string] $K2sRoot,
        
        [Parameter(Mandatory = $false)]
        [string] $Proxy
    )
    Write-Log 'Downloading cert-manager CLI tools' -Console
    
    $manifest = Get-FromYamlFile -Path $ManifestPath
    
    # Get the first implementation (nginx) which contains the cmctl download specification
    $windowsCurlPackages = $manifest.spec.implementations[0].offline_usage.windows.curl
    
    if ($windowsCurlPackages) {
        foreach ($package in $windowsCurlPackages) {
            $destination = $package.destination
            $destination = "$K2sRoot\$destination"
            # Normalize path to ensure Test-Path works correctly
            $destination = [System.IO.Path]::GetFullPath($destination)
            
            if (!(Test-Path $destination)) {
                $url = $package.url
                Invoke-DownloadFile $destination $url $true -ProxyToUse $Proxy
            }
            else {
                Write-Log "File $destination already exists. Skipping download." -Console
            }
        }
    }
}

<#
.SYNOPSIS
Installs cert-manager controllers in the cluster.
.DESCRIPTION
Applies cert-manager YAML manifest and waits for API readiness.
Throws error if cert-manager fails to become ready.
.PARAMETER EncodeStructuredOutput
Whether to encode error output for CLI consumption.
.PARAMETER MessageType
Message type for structured CLI output.
#>
function Install-CertManagerControllers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch] $EncodeStructuredOutput,
        [Parameter(Mandatory = $false)]
        [string] $MessageType
    )

    Write-Log 'Installing cert-manager' -Console
    $certManagerConfig = Get-CertManagerConfig
    (Invoke-Kubectl -Params 'apply', '-f', $certManagerConfig).Output | Write-Log

    Write-Log 'Waiting for cert-manager APIs to be ready, be patient!' -Console
    $certManagerStatus = Wait-ForCertManagerAvailable
    
    if ($certManagerStatus -ne $true) {
        $errMsg = "cert-manager is not ready. Please use cmctl.exe to investigate.`nInstallation of 'cert-manager' failed."
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        }
        throw $errMsg
    }
}

<#
.SYNOPSIS
Initializes CA ClusterIssuer for cert-manager.
.DESCRIPTION
Applies CA ClusterIssuer manifest, waits for root certificate creation,
and renews all existing certificates using the new CA.
.PARAMETER EncodeStructuredOutput
Whether to encode error output for CLI consumption.
.PARAMETER MessageType
Message type for structured CLI output.
#>
function Initialize-CACertificateIssuer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch] $EncodeStructuredOutput,
        [Parameter(Mandatory = $false)]
        [string] $MessageType
    )

    Write-Log 'Configuring CA ClusterIssuer' -Console
    $caIssuerConfig = Get-CAIssuerConfig
    (Invoke-Kubectl -Params 'apply', '-f', $caIssuerConfig).Output | Write-Log

    Write-Log 'Waiting for CA root certificate to be created' -Console
    $caCreated = Wait-ForCARootCertificate
    
    if ($caCreated -ne $true) {
        $errMsg = "CA root certificate 'ca-issuer-root-secret' not found.`nInstallation of 'cert-manager' failed."
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        }
        throw $errMsg
    }

    # Write-Log 'Renewing old Certificates using the new CA Issuer' -Console
    Update-CertificateResources
}

<#
.DESCRIPTION
Waits for the cert-manager API to be available.
#>
function Wait-ForCertManagerAvailable {
    $out = &$cmctlExe check api --wait=3m
    if ($out -match 'The cert-manager API is ready') {
        return $true
    }
    return $false
}

<#
.DESCRIPTION
Marks all cert-manager Certificate resources for renewal.
#>
function Update-CertificateResources {
    &$cmctlExe renew --all --all-namespaces
}

<#
.DESCRIPTION
Waits for the kubernetes secret 'ca-issuer-root-secret' in the namespace 'cert-manager' to be created.
#>
function Wait-ForCARootCertificate(
    [int]$SleepDurationInSeconds = 10,
    [int]$NumberOfRetries = 10) {
    for (($i = 1); $i -le $NumberOfRetries; $i++) {
        $out = (Invoke-Kubectl -Params '-n', 'cert-manager', 'get', 'secrets', 'ca-issuer-root-secret', '-o=jsonpath="{.metadata.name}"', '--ignore-not-found').Output
        if ($out -match 'ca-issuer-root-secret') {
            Write-Log "'ca-issuer-root-secret' created and ready for use."
            return $true
        }
        Write-Log "Retry {$i}: 'ca-issuer-root-secret' not yet created. Will retry after $SleepDurationInSeconds Seconds" -Console
        Start-Sleep -Seconds $SleepDurationInSeconds
    }
    return $false
}

function Remove-Cmctl {
    Write-Log "Removing $cmctlExe.."
    Remove-Item -Path $cmctlExe -Force -ErrorAction SilentlyContinue
}

function Get-TrustedRootStoreLocation {
    return 'Cert:\LocalMachine\Root'
}

function Get-CAIssuerName {
    return 'K2s Self-Signed CA'
}


<#
.SYNOPSIS
Imports CA certificate to Windows trusted root store.
.DESCRIPTION
Extracts CA certificate from Kubernetes secret and imports it to
Windows trusted certificate authorities.
#>
function Import-CACertificateToWindowsStore {
    [CmdletBinding()]
    param()

    Write-Log 'Importing CA root certificate to trusted authorities of your computer' -Console
    
    $b64secret = (Invoke-Kubectl -Params '-n', 'cert-manager', 'get', 'secrets', 'ca-issuer-root-secret', '-o', 'jsonpath', '--template', '{.data.ca\.crt}').Output
    $tempFile = New-TemporaryFile
    $certLocationStore = Get-TrustedRootStoreLocation
    
    [Text.Encoding]::Utf8.GetString([Convert]::FromBase64String($b64secret)) | Out-File -Encoding utf8 -FilePath $tempFile.FullName -Force
    
    $params = @{
        FilePath          = $tempFile.FullName
        CertStoreLocation = $certLocationStore
    }
    Import-Certificate @params
    Remove-Item -Path $tempFile.FullName -Force
}

<#
.DESCRIPTION
Orchestrates complete cert-manager installation:
- Downloads cmctl.exe CLI tool
- Installs cert-manager controllers
- Configures CA ClusterIssuer
- Imports CA certificate to Windows trust store

Handles all errors internally and exits on failure.
.PARAMETER Proxy
Optional proxy server to use for downloads.
.PARAMETER EncodeStructuredOutput
Whether to encode error output for CLI consumption.
.PARAMETER MessageType
Message type for structured CLI output.
.EXAMPLE
Enable-CertManager -Proxy 'http://proxy.example.com:8080'
#>
function Enable-CertManager {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string] $Proxy,
        [Parameter(Mandatory = $false)]
        [switch] $EncodeStructuredOutput,
        [Parameter(Mandatory = $false)]
        [string] $MessageType
    )
    try {
   
		$manifestPath = "$PSScriptRoot\ingress\addon.manifest.yaml"
        $k2sRoot = "$PSScriptRoot\.."
        
        Install-CmctlCli -ManifestPath $manifestPath -K2sRoot $k2sRoot -Proxy $Proxy
        Install-CertManagerControllers -EncodeStructuredOutput:$EncodeStructuredOutput -MessageType $MessageType
        
        Initialize-CACertificateIssuer -EncodeStructuredOutput:$EncodeStructuredOutput -MessageType $MessageType
        
        Import-CACertificateToWindowsStore

        Write-Log 'cert-manager installation completed successfully' -Console
    }
    catch {
        $errMsg = "cert-manager installation failed: $($_.Exception.Message)"
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            exit 1
        }
        Write-Log $errMsg -Error
        exit 1
    }
}

<#
.SYNOPSIS
Creates a standardized status property object for addon status reporting.
.DESCRIPTION
Provides consistent status property format across all addons with Name, Value, Okay, and Message fields.
.PARAMETER Name
The name of the status property (e.g., 'IsCertManagerAvailable').
.PARAMETER Value
The boolean value indicating the status (typically result from a test function).
.PARAMETER SuccessMessage
The message to display when Value is $true.
.PARAMETER FailureMessage
The message to display when Value is $false.
.EXAMPLE
$certManagerProp = New-AddonStatusProperty `
    -Name 'IsCertManagerAvailable' `
    -Value (Wait-ForCertManagerAvailable) `
    -SuccessMessage 'The cert-manager API is ready' `
    -FailureMessage 'The cert-manager API is not ready. Please use cmctl.exe for diagnostics.'
#>
function New-AddonStatusProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,
        
        [Parameter(Mandatory = $true)]
        [bool] $Value,
        
        [Parameter(Mandatory = $true)]
        [string] $SuccessMessage,
        
        [Parameter(Mandatory = $true)]
        [string] $FailureMessage
    )
    
    $property = @{
        Name = $Name
        Value = $Value
        Okay = $Value
        Message = if ($Value) { $SuccessMessage } else { $FailureMessage }
    }
    
    return $property
}

<#
.SYNOPSIS
Gets the path to Gateway API CRDs manifest file.
.DESCRIPTION
Returns the absolute path to the Gateway API v1.4.1 CRDs YAML manifest in the common addon folder.
#>
function Get-GatewayApiCrdsConfig {
    return "$PSScriptRoot\common\manifests\crds\gateway-crds\gateway-api-v1.4.1.yaml"
}

<#
.SYNOPSIS
Installs Gateway API CRDs in the cluster.
.DESCRIPTION
Applies Gateway API v1.4.1 Custom Resource Definitions (GatewayClass, Gateway, HTTPRoute, etc.)
used by ingress controllers like nginx-gw and traefik.
.EXAMPLE
Install-GatewayApiCrds
#>
function Install-GatewayApiCrds {
    [CmdletBinding()]
    param()

    Write-Log 'Installing Gateway API CRDs' -Console
    $gatewayApiCrds = Get-GatewayApiCrdsConfig
    (Invoke-Kubectl -Params 'apply', '-f', $gatewayApiCrds).Output | Write-Log
}

<#
.SYNOPSIS
Uninstalls Gateway API CRDs from the cluster.
.DESCRIPTION
Removes Gateway API v1.4.1 Custom Resource Definitions from the cluster.
Warning: This will fail if any Gateway, HTTPRoute, or other Gateway API resources still exist.
.EXAMPLE
Uninstall-GatewayApiCrds
#>
function Uninstall-GatewayApiCrds {
    [CmdletBinding()]
    param()

    Write-Log 'Uninstalling Gateway API CRDs' -Console
    $gatewayApiCrds = Get-GatewayApiCrdsConfig
    (Invoke-Kubectl -Params 'delete', '--ignore-not-found', '--timeout=30s', '-f', $gatewayApiCrds).Output | Write-Log
}

<#
.SYNOPSIS
Gets cert-manager status properties for addon status reporting.
.DESCRIPTION
Returns two status properties:
1. IsCertManagerAvailable - checks if cert-manager API is ready
2. IsCaRootCertificateAvailable - checks if CA root certificate secret exists
.EXAMPLE
$certManagerProps = Get-CertManagerStatusProperties
return $isIngressRunningProp, $certManagerProps
#>
function Get-CertManagerStatusProperties {
    [CmdletBinding()]
    param()
    
    $certManagerAvailable = Wait-ForCertManagerAvailable
    $certManagerProp = @{
        Name = 'IsCertManagerAvailable'
        Value = $certManagerAvailable
        Okay = $certManagerAvailable
        Message = if ($certManagerAvailable) { 'The cert-manager API is ready' } else { 'The cert-manager API is not ready. Please use cmctl.exe for further diagnostics.' }
    }
    
    $caRootCertificateAvailable = Wait-ForCARootCertificate
    $caRootCertificateProp = @{
        Name = 'IsCaRootCertificateAvailable'
        Value = $caRootCertificateAvailable
        Okay = $caRootCertificateAvailable
        Message = if ($caRootCertificateAvailable) { 'The CA root certificate is available' } else { "The CA root certificate is not available ('ca-issuer-root-secret' not created)." }
    }
    
    return $certManagerProp, $caRootCertificateProp
}

<#
.SYNOPSIS
Disables and uninstalls cert-manager from the cluster.
.DESCRIPTION
Removes cert-manager components:
- Deletes CA ClusterIssuer
- Uninstalls cert-manager controllers
- Removes cmctl.exe CLI tool
- Removes CA certificate from Windows trusted root store
.EXAMPLE
Uninstall-CertManager
#>
function Uninstall-CertManager {
    [CmdletBinding()]
    param()

    Write-Log 'Uninstalling cert-manager' -Console
    
    $certManagerConfig = Get-CertManagerConfig
    $caIssuerConfig = Get-CAIssuerConfig

    (Invoke-Kubectl -Params 'delete', '--ignore-not-found', '--timeout=30s', '-f', $caIssuerConfig).Output | Write-Log
    (Invoke-Kubectl -Params 'delete', '--ignore-not-found', '--timeout=30s', '-f', $certManagerConfig).Output | Write-Log

    Remove-Cmctl

    Write-Log 'Removing CA issuer certificate from trusted root' -Console
    $caIssuerName = Get-CAIssuerName
    $trustedRootStoreLocation = Get-TrustedRootStoreLocation
    Get-ChildItem -Path $trustedRootStoreLocation | Where-Object { $_.Subject -match $caIssuerName } | Remove-Item
}

function Wait-ForK8sSecret {
    param (
        [Parameter(Mandatory = $true)]
        [string]$SecretName,
        [Parameter(Mandatory = $true)]
        [string]$Namespace,
        [int]$TimeoutSeconds = 60,
        [int]$CheckIntervalSeconds = 4
    )

    $startTime = Get-Date
    $endTime = $startTime.AddSeconds($TimeoutSeconds)

    $kubeToolsPath = Get-KubeToolsPath
    while ((Get-Date) -lt $endTime) {
        try {
            $secret = &"$kubeToolsPath\kubectl.exe" get secret $SecretName -n $Namespace --ignore-not-found
            if ($secret) {
                Write-Log "Secret '$SecretName' is available." -Console
                return $true
            }
        }
        catch {
            Write-Log "Error checking for secret: $_" -Console
        }

        Start-Sleep -Seconds $CheckIntervalSeconds
    }

    Write-Log "Timed out waiting for secret '$SecretName' in namespace '$Namespace'." -Console
    return $false
}
<#
.SYNOPSIS
Asserts TLS certificate exists in ingress namespace.
.DESCRIPTION
Checks if k2s-cluster-local-tls secret exists in the ingress namespace.
If not found, re-applies the Certificate manifest to trigger cert-manager creation.
.PARAMETER IngressType
Type of ingress controller (nginx, traefik, or nginx-gw).
.PARAMETER CertificateManifestPath
Optional path to the Certificate manifest. If not provided, derived from ingress type.
.EXAMPLE
Assert-IngressTlsCertificate -IngressType 'nginx'
#>
function Assert-IngressTlsCertificate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('nginx', 'traefik', 'nginx-gw')]
        [string] $IngressType,

        [Parameter(Mandatory = $false)]
        [string] $CertificateManifestPath
    )

    $namespace = switch ($IngressType) {
        'nginx' { 'ingress-nginx' }
        'traefik' { 'ingress-traefik' }
        'nginx-gw' { 'nginx-gw' }
    }

    Write-Log "Verifying TLS certificate exists in $namespace namespace" -Console
    $certExists = Wait-ForK8sSecret -SecretName 'k2s-cluster-local-tls' -Namespace $namespace -TimeoutSeconds 30

    if (-not $certExists) {
        Write-Log "Certificate not found, applying Certificate manifest to trigger creation" -Console
        (Invoke-Kubectl -Params 'apply', '-f', $CertificateManifestPath).Output | Write-Log
        $certExists = Wait-ForK8sSecret -SecretName 'k2s-cluster-local-tls' -Namespace $namespace -TimeoutSeconds 60

        if (-not $certExists) {
            Write-Log "Warning: TLS certificate still not available after applying manifest" -Console
        }
    }
    else {
        Write-Log "TLS certificate already exists in $namespace namespace" -Console
    }

    return $certExists
}

Export-ModuleMember -Function Get-EnabledAddons, Add-AddonToSetupJson, Remove-AddonFromSetupJson,
Install-DebianPackages, Get-DebianPackageAvailableOffline, Test-IsAddonEnabled, Invoke-AddonsHooks, Copy-ScriptsToHooksDir,
Remove-ScriptsFromHooksDir, Get-AddonConfig, Backup-Addons, Restore-Addons, Get-AddonStatus, Find-AddonManifests,
Get-ErrCodeAddonAlreadyDisabled, Get-ErrCodeAddonAlreadyEnabled, Get-ErrCodeAddonEnableFailed, Get-ErrCodeAddonNotFound, Get-ErrCodeInvalidParameter,
Add-HostEntries, Get-AddonsConfig, Update-Addons, Update-IngressForAddon, Test-NginxIngressControllerAvailability, Test-TraefikIngressControllerAvailability,
Test-KeyCloakServiceAvailability, Enable-IngressAddon, Remove-IngressForTraefik, Remove-IngressForNginx, Get-AddonProperties, Get-IngressNginxConfigDirectory, 
Update-IngressForTraefik, Update-IngressForNginx, Get-IngressNginxSecureConfig, Get-IngressTraefikConfig, Enable-StorageAddon, Get-AddonNameFromFolderPath, 
Test-LinkerdServiceAvailability, Test-TrustManagerServiceAvailability, Test-KeyCloakServiceAvailability, Get-IngressTraefikSecureConfig, Write-BrowserWarningForUser,
Get-ImagesFromYamlFiles, Get-ImagesFromYaml, Remove-VersionlessImages, Get-IngressNginxGatewayConfig, Remove-IngressForNginxGateway, Update-IngressForNginxGateway, Test-NginxGatewayAvailability, Get-IngressNginxGatewaySecureConfig,
Get-CertManagerConfig, Get-CAIssuerConfig, Install-CmctlCli, Install-CertManagerControllers, Initialize-CACertificateIssuer, Import-CACertificateToWindowsStore, Enable-CertManager, Uninstall-CertManager, New-AddonStatusProperty, Get-CertManagerStatusProperties, Wait-ForCertManagerAvailable,
Get-GatewayApiCrdsConfig, Install-GatewayApiCrds, Uninstall-GatewayApiCrds, Assert-IngressTlsCertificate, Wait-ForK8sSecret