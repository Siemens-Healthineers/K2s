# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
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

function Assert-AddonPathToken {
	param (
		[parameter(Mandatory = $true)]
		[string] $Value,
		[parameter(Mandatory = $true)]
		[string] $ParameterName
	)

	if ([string]::IsNullOrWhiteSpace($Value)) {
		throw "Addon '$ParameterName' must not be empty."
	}

	if ($Value -notmatch '^[A-Za-z0-9._-]+$') {
		throw "Invalid addon '$ParameterName' value '$Value'. Allowed characters: letters, digits, dot, underscore, dash."
	}

	return $Value
}

function Resolve-AddonImplementationToken {
	param (
		[parameter(Mandatory = $false)]
		$Implementation,
		[parameter(Mandatory = $true)]
		[string] $AddonName
	)

	if ($null -eq $Implementation) {
		return $null
	}

	if ($Implementation -is [System.Collections.IEnumerable] -and $Implementation -isnot [string]) {
		# Evidence: legacy migration shapes existed where Implementation was emitted as an array,
		# while re-enable uses strict token validation in Enable-AddonFromConfig.
		$firstValidToken = $null
		foreach ($candidate in $Implementation) {
			if ($null -eq $candidate) {
				continue
			}

			$candidateToken = [string]$candidate
			if ([string]::IsNullOrWhiteSpace($candidateToken)) {
				continue
			}

			if ($candidateToken -match '^[A-Za-z0-9._-]+$') {
				$firstValidToken = $candidateToken
				break
			}
		}

		if ($null -eq $firstValidToken) {
			Write-Log "[Addons] Addon '$AddonName' contains legacy implementation array without valid tokens. Ignoring implementation value."
			return $null
		}

		Write-Log "[Addons] Addon '$AddonName' contains legacy implementation array. Using '$firstValidToken'."
		return (Assert-AddonPathToken -Value $firstValidToken -ParameterName 'Implementation')
	}

	return (Assert-AddonPathToken -Value ([string]$Implementation) -ParameterName 'Implementation')
}

function Assert-AddonScriptPathWithinRoot {
	param (
		[parameter(Mandatory = $true)]
		[string] $Root,
		[parameter(Mandatory = $true)]
		[string] $ScriptPath
	)

	$normalizedRoot = [System.IO.Path]::GetFullPath($Root)
	$normalizedRoot = $normalizedRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
	$normalizedScriptPath = [System.IO.Path]::GetFullPath($ScriptPath)
	$rootPrefix = $normalizedRoot + [System.IO.Path]::DirectorySeparatorChar

	if (($normalizedScriptPath -ne $normalizedRoot) -and (-not $normalizedScriptPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase))) {
		throw "Resolved addon script path '$normalizedScriptPath' escapes addon root '$normalizedRoot'."
	}

	return $normalizedScriptPath
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

	$Root = [System.IO.Path]::GetFullPath($Root)

	$addonNameToken = Assert-AddonPathToken -Value $Config.Name -ParameterName 'Name'
	$dirName = $addonNameToken
	$addonName = $Config.Name
	$implementationToken = Resolve-AddonImplementationToken -Implementation $Config.Implementation -AddonName $Config.Name
	if ($null -ne $implementationToken) {
		$dirName += "\$implementationToken"
		$addonName += " $implementationToken"
	}

	$enableCmdPath = Assert-AddonScriptPathWithinRoot -Root $Root -ScriptPath (Join-Path -Path $Root -ChildPath (Join-Path -Path $dirName -ChildPath 'Enable.ps1'))

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
				'ingress-nginx' { $newAddon = [pscustomobject]@{Name = 'ingress'; Implementation = 'nginx' } }
				'traefik' { $newAddon = [pscustomobject]@{Name = 'ingress'; Implementation = 'traefik' } }
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
	Updates the Version property of an enabled addon entry in setup.json
.DESCRIPTION
	Finds the first EnabledAddons entry matching the given Name and sets its Version property.
	Adds the property if absent or updates it if already present.
.PARAMETER Name
	Name of the enabled addon
.PARAMETER Version
	Version string to set on the addon entry
.EXAMPLE
	Update-AddonVersionInSetupJson -Name 'dashboard' -Version '1.2.3'
#>
function Update-AddonVersionInSetupJson {
	param (
		[Parameter(Mandatory = $true)]
		[string]$Name = $(throw 'Please specify the addon name.'),
		[Parameter(Mandatory = $true)]
		[string]$Version = $(throw 'Please specify the version.')
	)

	$filePath = Get-SetupConfigFilePath
	$parsedSetupJson = Get-Content -Raw $filePath | ConvertFrom-Json

	$enabledAddonMemberExists = Get-Member -InputObject $parsedSetupJson -Name $ConfigKey_EnabledAddons -MemberType Properties
	if (!$enabledAddonMemberExists) {
		Write-Log "No EnabledAddons property found in setup.json, skipping version update for '$Name'"
		return
	}

	$addonEntry = $parsedSetupJson.EnabledAddons | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
	if ($null -eq $addonEntry) {
		Write-Log "Addon '$Name' not found in EnabledAddons, skipping version update"
		return
	}

	$versionMemberExists = Get-Member -InputObject $addonEntry -Name 'Version' -MemberType Properties
	if ($versionMemberExists) {
		$addonEntry.Version = $Version
	}
	else {
		$addonEntry | Add-Member -NotePropertyName 'Version' -NotePropertyValue $Version
	}

	$parsedSetupJson | ConvertTo-Json -Depth 100 | Set-Content -Force $filePath -Confirm:$false
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
				$newEnabledAddons = @($enabledAddons | Where-Object { -not (($_.Name -eq $Addon.Name) -and ($_.Implementation -eq $Addon.Implementation)) })
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
		[string[]]$packages,
		[parameter()]
		[switch] $AllowRuntimeDownload
	)

	function Assert-RemoteShellPathSegment {
		param (
			[parameter(Mandatory = $true)]
			[string] $Value,
			[parameter(Mandatory = $true)]
			[string] $ParameterName
		)

		if ([string]::IsNullOrWhiteSpace($Value)) {
			throw "Path segment '$ParameterName' must not be empty."
		}

		if ($Value -notmatch '^[A-Za-z0-9._-]+$') {
			throw "Invalid path segment '$ParameterName' value '$Value'. Allowed characters: letters, digits, dot, underscore, dash."
		}

		return $Value
	}

	function Assert-DebianPackageToken {
		param (
			[parameter(Mandatory = $true)]
			[string] $Value,
			[parameter(Mandatory = $true)]
			[string] $ParameterName
		)

		if ([string]::IsNullOrWhiteSpace($Value)) {
			throw "Package '$ParameterName' must not be empty."
		}

		if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9.+:-]*$') {
			throw "Invalid Debian package token '$ParameterName' value '$Value'."
		}

		return $Value
	}

	function Test-ExplicitRuntimeDebianDownloadAllowed {
		param (
			[parameter(Mandatory = $false)]
			[switch] $AllowBySwitch
		)

		if ($AllowBySwitch) {
			return $true
		}

		$allowFromEnv = [Environment]::GetEnvironmentVariable('K2S_ALLOW_RUNTIME_DEBIAN_DOWNLOAD')
		if ($allowFromEnv -and $allowFromEnv -match '^(?i:true|1|yes)$') {
			return $true
		}

		return $false
	}

	# Evidence: addon/implementation/package values are injected into remote shell commands in this function and in Get-DebianPackageAvailableOffline.
	$addon = Assert-RemoteShellPathSegment -Value $addon -ParameterName 'addon'
	$dirName = $addon
	if (($implementation -ne '') -and ($implementation -ne $addon)) {
		$implementation = Assert-RemoteShellPathSegment -Value $implementation -ParameterName 'implementation'
		$dirName += "_$implementation"
	}

	$runtimeDownloadAllowed = Test-ExplicitRuntimeDebianDownloadAllowed -AllowBySwitch:$AllowRuntimeDownload

	foreach ($package in $packages) {
		$package = Assert-DebianPackageToken -Value $package -ParameterName 'package'
		$remotePackageDir = "./$dirName/$package"
		$remotePackageDirQuoted = "'$remotePackageDir'"

		if (!(Get-DebianPackageAvailableOffline -addon $addon -implementation $implementation -package $package)) {
			if (-not $runtimeDownloadAllowed) {
				throw "Package '$package' is not available in offline cache '$remotePackageDir'. Runtime download is blocked by offline policy. Re-import addon package content or explicitly allow runtime Debian downloads via -AllowRuntimeDownload or K2S_ALLOW_RUNTIME_DEBIAN_DOWNLOAD=true."
			}

			Write-Log "Offline cache missing for '$package'. Runtime download explicitly allowed; fetching package dependencies."
			(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "mkdir -p $remotePackageDirQuoted && cd $remotePackageDirQuoted && sudo chown -R _apt:root .").Output | Write-Log
			(Invoke-CmdOnControlPlaneViaSSHKey -Retries 2 -Timeout 2 -CmdToExecute "cd $remotePackageDirQuoted && sudo apt-get download -- $package" -RepairCmd 'sudo dpkg --configure -a; sudo apt --fix-broken install').Output | Write-Log
			(Invoke-CmdOnControlPlaneViaSSHKey `
				-Retries 2 `
				-Timeout 2 `
				-CmdToExecute "cd $remotePackageDirQuoted && sudo DEBIAN_FRONTEND=noninteractive apt-get --reinstall install -y --no-install-recommends --no-install-suggests --simulate ./$package*.deb | grep 'Inst ' | cut -d ' ' -f 2 | sort -u | xargs -r sudo apt-get download --" `
				-RepairCmd 'sudo dpkg --configure -a; sudo apt --fix-broken install').Output | Write-Log
		}

		Write-Log "Installing $package offline."
		(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo dpkg -i $remotePackageDirQuoted/*.deb 2>&1").Output | Write-Log
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

	function Assert-RemoteShellPathSegment {
		param (
			[parameter(Mandatory = $true)]
			[string] $Value,
			[parameter(Mandatory = $true)]
			[string] $ParameterName
		)

		if ([string]::IsNullOrWhiteSpace($Value)) {
			throw "Path segment '$ParameterName' must not be empty."
		}

		if ($Value -notmatch '^[A-Za-z0-9._-]+$') {
			throw "Invalid path segment '$ParameterName' value '$Value'. Allowed characters: letters, digits, dot, underscore, dash."
		}

		return $Value
	}

	function Assert-DebianPackageToken {
		param (
			[parameter(Mandatory = $true)]
			[string] $Value,
			[parameter(Mandatory = $true)]
			[string] $ParameterName
		)

		if ([string]::IsNullOrWhiteSpace($Value)) {
			throw "Package '$ParameterName' must not be empty."
		}

		if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9.+:-]*$') {
			throw "Invalid Debian package token '$ParameterName' value '$Value'."
		}

		return $Value
	}

	$addon = Assert-RemoteShellPathSegment -Value $addon -ParameterName 'addon'
	$package = Assert-DebianPackageToken -Value $package -ParameterName 'package'
	$dirName = $addon
	if (($implementation -ne '') -and ($implementation -ne $addon)) {
		$implementation = Assert-RemoteShellPathSegment -Value $implementation -ParameterName 'implementation'
		$dirName += "_$implementation"
	}

	$remotePackageDir = "./$dirName/$package"
	$remotePackageDirQuoted = "'$remotePackageDir'"

	# Evidence: this module already uses Invoke-CmdOnControlPlaneViaSSHKey for remote package checks/install commands.
	# TODO: NOTE: DO NOT USE `ExecCmdMaster` here to get the return value.
	$remoteDirCheck = Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "[ -d $remotePackageDirQuoted ]"
	if (-not $remoteDirCheck.Success) {
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
	$addonImplementation = [string]$Addon.Implementation
	$hasAddonImplementation = -not [string]::IsNullOrWhiteSpace($addonImplementation)
	foreach ($enabledAddon in $enabledAddons) {
		if ($enabledAddon.Name -eq $Addon.Name) {
			if (-not $hasAddonImplementation) {
				return $true
			}

			if ($enabledAddon.Implementation -eq $addonImplementation) {
				return $true
			} 
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
		$resolvedHooksDir = [System.IO.Path]::GetFullPath($hooksDir)
		$unsafeNamePattern = '[\\/:*?"<>|]'

		foreach ($name in $ScriptNames) {
			$scriptName = [string]$name
			if ([string]::IsNullOrWhiteSpace($scriptName) -or
				$scriptName -match $unsafeNamePattern -or
				$scriptName.Contains('..')) {
				Write-Warning "Skipping invalid addon hook script name '$scriptName'."
				continue
			}

			$path = Join-Path -Path $hooksDir -ChildPath $scriptName
			$resolvedPath = [System.IO.Path]::GetFullPath($path)

			if (-not $resolvedPath.StartsWith($resolvedHooksDir, [System.StringComparison]::OrdinalIgnoreCase)) {
				Write-Warning "Skipping addon hook '$scriptName' because resolved path is outside hooks dir."
				continue
			}

			if ((Test-Path -Path $path) -ne $true) {
				Write-Warning "Cannot remove addon hook '$path' because it does not exist."
				continue
			}

			Remove-Item -Path $path -Force

			Write-Log "  Hook '$scriptName' removed."
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
	function ConvertTo-ShSingleQuotedString {
		param(
			[Parameter(Mandatory = $true)]
			[string] $Value
		)
		"'" + ($Value -replace "'", "'`"'`"'") + "'"
	}

	if ([string]::IsNullOrWhiteSpace($Url) -or $Url -notmatch '^[A-Za-z0-9._-]+$') {
		throw "[Hosts] Invalid host token '$Url'."
	}

	$controlPlaneIp = Get-ConfiguredIPControlPlane
	if (-not [System.Net.IPAddress]::TryParse($controlPlaneIp, [ref]([System.Net.IPAddress]$null))) {
		throw "[Hosts] Invalid control plane IP '$controlPlaneIp'."
	}

	Write-Log "Adding host entry for '$Url'.." -Console

	# add in control plane
	$hostEntry = "$controlPlaneIp $Url"
	if ($hostEntry -match '[\r\n]') {
		throw '[Hosts] Invalid host entry format.'
	}
	$entryArg = ConvertTo-ShSingleQuotedString -Value $hostEntry
	$hostsFileArg = ConvertTo-ShSingleQuotedString -Value '/etc/hosts'
	$remoteCmd = "grep -qxF -- $entryArg $hostsFileArg || printf '%s\n' $entryArg | sudo tee -a $hostsFileArg > /dev/null"
	(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute $remoteCmd).Output | Write-Log

	$hostFile = 'C:\Windows\System32\drivers\etc\hosts'

	# add in host
	if (!$(Get-Content $hostFile | ForEach-Object { $_ -match $hostEntry }).Contains($true)) {
		Add-Content $hostFile $hostEntry
	}
}

<#
.SYNOPSIS
    Adds a static host entry to the CoreDNS hosts block.
.DESCRIPTION
    Injects "ipAddress hostname" into the CoreDNS ConfigMap hosts {} block,
    anchored after the existing k2s.cluster.local line. Idempotent: no-op when
    the hostname is already present.
#>
function Add-CoreDNSHostEntry {
    param (
        [Parameter(Mandatory = $true)]
        [string] $Hostname
    )
    $ipAddress = Get-ConfiguredIPControlPlane
    Write-Log "Adding '$ipAddress $Hostname' to CoreDNS hosts block.." -Console

    $result = Invoke-Kubectl -Params 'get', 'configmap', 'coredns', '-n', 'kube-system', '-o', 'jsonpath={.data.Corefile}'
    if (-not $result.Success) {
        throw "[CoreDNS] Failed to read CoreDNS ConfigMap: $($result.Output)"
    }

    $corefile = $result.Output -replace "`r", ''
    if ($corefile -match [regex]::Escape($Hostname)) {
        Write-Log "[CoreDNS] '$Hostname' already in CoreDNS hosts block, skipping"
        return
    }

    $injected = $false
    $newLines = foreach ($line in ($corefile -split "`n")) {
        $line
        if (-not $injected -and $line -match [regex]::Escape('k2s.cluster.local')) {
            "    $ipAddress $Hostname"
            $injected = $true
        }
    }

    if (-not $injected) {
        throw "[CoreDNS] Anchor 'k2s.cluster.local' not found in CoreDNS Corefile; cannot add entry"
    }

    $newCorefile = $newLines -join "`n"
    $patch = [ordered]@{ data = [ordered]@{ Corefile = $newCorefile } } | ConvertTo-Json -Compress -Depth 5
    $patchFile = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($patchFile, $patch, [System.Text.Encoding]::UTF8)
        $patchResult = Invoke-Kubectl -Params 'patch', 'configmap', 'coredns', '-n', 'kube-system', '--type=merge', "--patch-file=$patchFile"
        if (-not $patchResult.Success) {
            throw "[CoreDNS] Failed to patch CoreDNS ConfigMap: $($patchResult.Output)"
        }
    }
    finally {
        Remove-Item -Path $patchFile -Force -ErrorAction SilentlyContinue
    }
    Write-Log "'$ipAddress $Hostname' added to CoreDNS hosts block" -Console
}

<#
.SYNOPSIS
    Removes a static host entry from the CoreDNS hosts block.
.DESCRIPTION
    Deletes the line containing Hostname from the CoreDNS ConfigMap hosts {} block.
    Reverse operation of Add-CoreDNSHostEntry; intended to be called on addon disable.
    Uses kubectl patch --type=merge so the update is atomic. Idempotent: no-op when the
    hostname is not present.
#>
function Remove-CoreDNSHostEntry {
    param (
        [Parameter(Mandatory = $true)]
        [string] $Hostname
    )
    Write-Log "Removing '$Hostname' from CoreDNS hosts block.." -Console

    $result = Invoke-Kubectl -Params 'get', 'configmap', 'coredns', '-n', 'kube-system', '-o', 'jsonpath={.data.Corefile}'
    if (-not $result.Success) {
        throw "[CoreDNS] Failed to read CoreDNS ConfigMap: $($result.Output)"
    }

    $corefile = $result.Output -replace "`r", ''
    if ($corefile -notmatch [regex]::Escape($Hostname)) {
        Write-Log "[CoreDNS] '$Hostname' not found in CoreDNS hosts block, skipping"
        return
    }

    $newCorefile = ($corefile -split "`n" | Where-Object { $_ -notmatch [regex]::Escape($Hostname) }) -join "`n"

    $patch = [ordered]@{ data = [ordered]@{ Corefile = $newCorefile } } | ConvertTo-Json -Compress -Depth 5
    $patchFile = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($patchFile, $patch, [System.Text.Encoding]::UTF8)
        $patchResult = Invoke-Kubectl -Params 'patch', 'configmap', 'coredns', '-n', 'kube-system', '--type=merge', "--patch-file=$patchFile"
        if (-not $patchResult.Success) {
            throw "[CoreDNS] Failed to patch CoreDNS ConfigMap: $($patchResult.Output)"
        }
    }
    finally {
        Remove-Item -Path $patchFile -Force -ErrorAction SilentlyContinue
    }
    Write-Log "'$Hostname' removed from CoreDNS hosts block" -Console
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
			$updateScriptPath = Assert-AddonScriptPathWithinRoot -Root $PSScriptRoot -ScriptPath (Join-Path -Path $PSScriptRoot -ChildPath (Join-Path -Path $props.Directory -ChildPath 'Update.ps1'))

			if (Test-Path -Path $updateScriptPath) {
				& $updateScriptPath
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

	$addonNameToken = Assert-AddonPathToken -Value ([string]$Addon.Name) -ParameterName 'Name'
	$addonName = $addonNameToken
	$directory = $addonNameToken
	$implementationToken = Resolve-AddonImplementationToken -Implementation $Addon.Implementation -AddonName $addonNameToken
	if ($null -ne $implementationToken) {
		$addonName += " $implementationToken"
		$directory += "\$implementationToken"
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
Creates a CA certificate ConfigMap for nginx-gw BackendTLSPolicy validation.
This function extracts the self-signed certificate from a backend service pod 
and creates a ConfigMap that can be referenced by BackendTLSPolicy.
.PARAMETER Namespace
The namespace where the pod and ConfigMap should be created
.PARAMETER PodLabel
The label selector to find the pod (e.g., 'app.kubernetes.io/name=kong')
.PARAMETER Port
The port number where the service is running with TLS (e.g., 8443)
.PARAMETER ConfigMapName
The name of the ConfigMap to create (e.g., 'kong-ca-cert','argocd-ca-cert')
#>
function New-BackendCACertConfigMap {
	param (
		[Parameter(Mandatory = $true)]
		[string]$Namespace,
		[Parameter(Mandatory = $true)]
		[string]$PodLabel,
		[Parameter(Mandatory = $true)]
		[int]$Port,
		[Parameter(Mandatory = $true)]
		[string]$ConfigMapName
	)
	
	Write-Log "Extracting CA certificate for BackendTLSPolicy from pod with label '$PodLabel' in namespace '$Namespace'" -Console
	
	# Wait for pod to be ready
	$waitResult = Wait-ForPodCondition -Label $PodLabel -Namespace $Namespace -Condition 'Ready' -TimeoutSeconds 60
	if (-not $waitResult) {
		throw "Pod with label '$PodLabel' in namespace '$Namespace' did not become ready within 60 seconds. Please use kubectl describe for more details."
	}
	
	# Get pod name
	$pod = (Invoke-Kubectl -Params 'get', 'pods', '-n', $Namespace, '-l', $PodLabel, '-o', 'jsonpath={.items[0].metadata.name}').Output
	
	if ($pod) {
		try {
			# Extract certificate from pod
			$certPath = [System.IO.Path]::GetTempPath() + "$ConfigMapName.crt"
			$configMapManifestPath = [System.IO.Path]::GetTempPath() + "$ConfigMapName.configmap.yaml"
			$extractCmd = "echo | openssl s_client -connect localhost:$Port 2>&1 | openssl x509 -outform PEM"
			
			# Get container name from pod spec (first container that's not linkerd-proxy or linkerd-init)
			$containerResult = (Invoke-Kubectl -Params 'get', 'pod', $pod, '-n', $Namespace, '-o', "jsonpath={.spec.containers[?(@.name!='linkerd-proxy')].name}")
			$containerName = if ($containerResult.Success -and $containerResult.Output) { 
				($containerResult.Output -split '\s+')[0] 
			} else { 
				$null 
			}
			
			if ($containerName) {
				Write-Log "Using container '$containerName' from pod '$pod'" -Console
				$cert = (Invoke-Kubectl -Params 'exec', '-n', $Namespace, $pod, '-c', $containerName, '--', 'sh', '-c', $extractCmd).Output
			} else {
				# Fallback to not specifying container (single container pods)
				$cert = (Invoke-Kubectl -Params 'exec', '-n', $Namespace, $pod, '--', 'sh', '-c', $extractCmd).Output
			}
			
			$cert | Out-File -FilePath $certPath -Encoding ascii
			
			# Evidence: Invoke-Kubectl uses the repo-controlled kubectl.exe path from k8s-api.module.psm1.
			# Create ConfigMap with the certificate
			$configMapManifest = (Invoke-Kubectl -Params 'create', 'configmap', $ConfigMapName, '-n', $Namespace, "--from-file=ca.crt=$certPath", '--dry-run=client', '-o', 'yaml').Output
			$configMapManifest | Out-File -FilePath $configMapManifestPath -Encoding ascii
			(Invoke-Kubectl -Params 'apply', '-f', $configMapManifestPath).Output | Write-Log
			
			# Clean up temp file
			Remove-Item -Path $certPath -ErrorAction SilentlyContinue
			Remove-Item -Path $configMapManifestPath -ErrorAction SilentlyContinue
			
			Write-Log "CA certificate ConfigMap '$ConfigMapName' created successfully in namespace '$Namespace'" -Console
		}
		catch {
			Write-Log "Warning: Could not extract certificate from pod '$pod': $_" -Console
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
			Write-Log "  Applying nginx ingress manifest for $($props.Name)..." -Console
			$kustomizationDir = Get-IngressNginxConfigDirectory -Directory $props.Directory
		}
	}
	else {
		Write-Log "  Applying nginx ingress manifest for $($props.Name)..." -Console
		$kustomizationDir = Get-IngressNginxConfigDirectory -Directory $props.Directory
	}
	Write-Log "   Apply in cluster folder: $($kustomizationDir)" -Console

	Write-Log '  [Webhook probe] Waiting for nginx admission webhook to accept connections (up to 120s)...' -Console
	$probeWaited = 0
	$probeMaxWait = 120
	do {
		$probeResult = Invoke-Kubectl -Params 'apply', '-k', $kustomizationDir, '--dry-run=server'
		$outputText = ($probeResult.Output | ForEach-Object { "$_" }) -join "`n"
		if ($probeResult.Success -and $outputText -notmatch 'connection refused' -and $outputText -notmatch 'deadline exceeded') {
			Write-Log "  [Webhook probe] Webhook is accepting connections after ${probeWaited}s" -Console
			break
		}
		$notReadyReason = if ($outputText -match 'deadline exceeded') { 'deadline exceeded' } else { 'connection refused' }
		Write-Log "  [Webhook probe] Webhook not ready at ${probeWaited}s ($notReadyReason) - waiting 5s..." -Console
		Start-Sleep -Seconds 5
		$probeWaited += 5
	} while ($probeWaited -lt $probeMaxWait)
	if ($probeWaited -ge $probeMaxWait) {
		Write-Log '  [Webhook probe] WARNING: webhook did not become reachable within 120s; apply attempts will likely fail' -Console
	}

	# Retry logic: the admission webhook may transiently reject the ingress if the
	# controller has not yet fully loaded the ConfigMap (e.g. annotations-risk-level).
	$maxRetries = 3
	$retryDelay = 10
	$applied = $false
	for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
		$result = Invoke-Kubectl -Params 'apply', '-k', $kustomizationDir
		if ($result.Success) {
			Write-Log "  Successfully applied ingress manifest for $($props.Name)" -Console
			$applied = $true
			break
		}
		Write-Log "  WARNING: Failed to apply ingress manifest for $($props.Name) (attempt $attempt/$maxRetries): $($result.Output)" -Console
		if ($attempt -lt $maxRetries) {
			Write-Log "  Retrying in $retryDelay seconds..." -Console
			Start-Sleep -Seconds $retryDelay
		}
	}
	if (-not $applied) {
		Write-Log "  ERROR: Failed to apply ingress manifest for $($props.Name) after $maxRetries attempts" -Console
		throw "[Ingress-Nginx] Failed to apply ingress manifest for '$($props.Name)' after $maxRetries attempts. " +
			"Check kubectl output above and nginx admission webhook availability."
	}
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

	# Check whether the nginx Ingress resource is actually deployed in the cluster.
	# The source manifest directories always exist on disk, so Test-Path on the
	# kustomization folder is not a reliable indicator — we must query the cluster.
	$nginxIngressExists = (Invoke-Kubectl -Params 'get', 'ingress', 'dashboard-nginx-cluster-local', '-n', 'dashboard', '--ignore-not-found').Output
	if ($nginxIngressExists) {
		# Both the standard (ingress-nginx) and secure (ingress-nginx-secure) variants
		# deploy an Ingress with the identical name 'dashboard-nginx-cluster-local'.
		# Delete both kustomizations with --ignore-not-found — whichever was applied will
		# be removed; the other delete is a safe no-op.
		$standardNginxConfig = Get-IngressNginxConfigDirectory -Directory $props.Directory
		$secureNginxConfig = Get-IngressNginxSecureConfig -Directory $props.Directory

		Write-Log "  Deleting nginx ingress manifest for $($props.Name)..." -Console
		Invoke-Kubectl -Params 'delete', '-k', $standardNginxConfig, '--ignore-not-found' | Out-Null
		Invoke-Kubectl -Params 'delete', '-k', $secureNginxConfig, '--ignore-not-found' | Out-Null
	}
	else {
		Write-Log "  No nginx ingress resource found for $($props.Name) in cluster, skipping delete."
	}
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

	$keycloakAvailable = Test-KeyCloakServiceAvailability
	Write-Log "KeyCloak available: $keycloakAvailable"

	$hydraAvailable = Test-HydraAvailability
	Write-Log "Hydra available: $hydraAvailable"

	if ($keycloakAvailable -or $hydraAvailable) {
		Write-Log "  Applying secure traefik ingress manifest for $($props.Name)..." -Console
		$kustomizationDir = Get-IngressTraefikSecureConfig -Directory $props.Directory
		# check if $kustomizationDir does not exist
		if (!(Test-Path -Path $kustomizationDir)) {
			Write-Log "  Applying traefik ingress manifest for $($props.Name)..." -Console
			$kustomizationDir = Get-IngressTraefikConfig -Directory $props.Directory
		}
	}
	else {
		Write-Log "  Applying traefik ingress manifest for $($props.Name)..." -Console
		$kustomizationDir = Get-IngressTraefikConfig -Directory $props.Directory
	}

	Write-Log "   Apply in cluster folder: $($kustomizationDir)" -Console
	$result = Invoke-Kubectl -Params 'apply', '-k', $kustomizationDir
	if ($result.Success) {
		Write-Log "  Successfully applied ingress manifest for $($props.Name)" -Console
	}
	else {
		Write-Log "  ERROR: Failed to apply ingress manifest for $($props.Name): $($result.Output)" -Console
	}
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

	# Check whether the traefik Ingress resource is actually deployed in the cluster.
	# The source manifest directories always exist on disk, so Test-Path on the
	# kustomization folder is not a reliable indicator — we must query the cluster.
	$traefikIngressExists = (Invoke-Kubectl -Params 'get', 'ingress', 'dashboard-traefik-cluster-local', '-n', 'dashboard', '--ignore-not-found').Output
	if ($traefikIngressExists) {
		# Both the standard (ingress-traefik) and secure (ingress-traefik-secure) variants
		# deploy an Ingress with the identical name 'dashboard-traefik-cluster-local'.
		# We cannot reliably determine which variant was applied by checking disk paths
		# (both directories always exist in the repo).
		# Solution: delete both kustomizations with --ignore-not-found — whichever was
		# applied will be removed; the other delete is a safe no-op.
		$standardTraefikConfig = Get-IngressTraefikConfig -Directory $props.Directory
		$secureTraefikConfig = Get-IngressTraefikSecureConfig -Directory $props.Directory

		Write-Log "  Deleting traefik ingress manifest for $($props.Name)..." -Console
		Invoke-Kubectl -Params 'delete', '-k', $standardTraefikConfig, '--ignore-not-found' | Out-Null
		Invoke-Kubectl -Params 'delete', '-k', $secureTraefikConfig, '--ignore-not-found' | Out-Null
	}
	else {
		Write-Log "  No traefik ingress resource found for $($props.Name) in cluster, skipping delete."
	}
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

	$keycloakAvailable = Test-KeyCloakServiceAvailability
	Write-Log "KeyCloak available: $keycloakAvailable"

	$hydraAvailable = Test-HydraAvailability
	Write-Log "Hydra available: $hydraAvailable"

	if ($keycloakAvailable -or $hydraAvailable) {
		Write-Log "  Applying secure nginx ingress gateway manifest for $($props.Name)..." -Console
		$ingressDir = Get-IngressNginxGatewaySecureConfig
		$kustomizationDir = "$PSScriptRoot\$($props.Directory)\manifests\$ingressDir"
		# check if $kustomizationDir does not exist
		if (!(Test-Path -Path $kustomizationDir)) {
			Write-Log "  Applying nginx ingress gateway manifest for $($props.Name)..." -Console
			$ingressDir = Get-IngressNginxGatewayConfig
			$kustomizationDir = "$PSScriptRoot\$($props.Directory)\manifests\$ingressDir"
		}
	}
	else {
		Write-Log "  Applying nginx ingress gateway manifest for $($props.Name)..." -Console
		$ingressDir = Get-IngressNginxGatewayConfig
		$kustomizationDir = "$PSScriptRoot\$($props.Directory)\manifests\$ingressDir"
	}

	Write-Log "   Apply in cluster folder: $($kustomizationDir)" -Console

	$maxRetries = 3
	$retryDelay = 10
	$applied = $false
	for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
		$result = Invoke-Kubectl -Params 'apply', '-k', $kustomizationDir, '--request-timeout=30s'
		if ($result.Success) {
			Write-Log "  Successfully applied ingress manifest for $($props.Name)" -Console
			$applied = $true
			break
		}
		Write-Log "  WARNING: Failed to apply ingress manifest for $($props.Name) (attempt $attempt/$maxRetries): $($result.Output)" -Console
		if ($attempt -lt $maxRetries) {
			Write-Log "  Retrying in $retryDelay seconds..." -Console
			Start-Sleep -Seconds $retryDelay
		}
	}
	if (-not $applied) {
		Write-Log "  ERROR: Failed to apply ingress manifest for $($props.Name) after $maxRetries attempts" -Console
		throw "[Ingress-NginxGw] Failed to apply ingress manifest for '$($props.Name)' after $maxRetries attempts. " +
			"Check kubectl output above and API server availability."
	}
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

	# Check whether the nginx-gw HTTPRoute resource is actually deployed in the cluster.
	# The source manifest directories always exist on disk, so Test-Path on the
	# kustomization folder is not a reliable indicator — we must query the cluster.
	# IMPORTANT: HTTPRoute is a CRD; when nginx-gw is NOT installed the CRD itself does
	# not exist and kubectl exits with a non-zero code, writing an error like
	# "the server doesn't have a resource type 'httproute'" to stderr (merged via 2>&1
	# into .Output).  We must therefore check BOTH Success=true AND non-empty Output to
	# avoid treating an API-discovery error as "resource exists".
	$gwRouteResult = Invoke-Kubectl -Params 'get', 'httproute', 'dashboard-nginx-gw-cluster-local', '-n', 'dashboard', '--ignore-not-found'
	if ($gwRouteResult.Success -and $gwRouteResult.Output) {
		# Both the standard (ingress-nginx-gw) and secure (ingress-nginx-gw-secure) variants
		# deploy resources with identical names (HTTPRoute + ReferenceGrant).
		# We cannot reliably determine which variant was applied by checking disk paths
		# (both directories always exist in the repo).
		# Solution: delete both kustomizations with --ignore-not-found — whichever was
		# applied will be removed; the other delete is a safe no-op.
		$standardIngressDir = Get-IngressNginxGatewayConfig
		$standardKustomizationDir = "$PSScriptRoot\$($props.Directory)\manifests\$standardIngressDir"
		$secureIngressDir = Get-IngressNginxGatewaySecureConfig
		$secureKustomizationDir = "$PSScriptRoot\$($props.Directory)\manifests\$secureIngressDir"

		Write-Log "  Deleting gateway manifest for $($props.Name)..." -Console
		Invoke-Kubectl -Params 'delete', '-k', $standardKustomizationDir, '--ignore-not-found' | Out-Null
		Invoke-Kubectl -Params 'delete', '-k', $secureKustomizationDir, '--ignore-not-found' | Out-Null
	}
	else {
		Write-Log "  No nginx gateway route resource found for $($props.Name) in cluster, skipping delete."
	}
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

function Resolve-AddonImportPath {
    param (
        [Parameter(Mandatory = $true)]
        [string]$AddonName,
        [Parameter(Mandatory = $false)]
        [string]$AddonImplementation
    )

	if ([string]::IsNullOrWhiteSpace($AddonImplementation) -or $AddonImplementation -eq $AddonName) {
		return @{
			BaseAddonName      = $AddonName
			ImplementationName = $null
		}
    }

    return @{
		BaseAddonName      = $AddonName
		ImplementationName = $AddonImplementation
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
    
    if (!$windowsCurlPackages) {
        return
    }
    foreach ($package in $windowsCurlPackages) {
		$destination = [string]$package.destination
        $url = $package.url
		$urlPath = ($url -split '\?')[0]
		$urlFileName = [System.IO.Path]::GetFileName($urlPath)

		if ($destination -notmatch '(?i)cmctl\.exe' -and $urlFileName -notmatch '(?i)^cmctl') {
			continue
		}

        if ($url -match '\.(zip|tar\.gz|tgz)(\?.*)?$') {
            Write-Log "Skipping archive package '$url' - handled by dedicated installer." -Console
            continue
        }

        $destination = "$K2sRoot\$destination"
        # Normalize path to ensure Test-Path works correctly
        $destination = [System.IO.Path]::GetFullPath($destination)
        
        if (Test-Path $destination) {
            Write-Log "File $destination already exists. Skipping download." -Console
            continue
        }
        Invoke-DownloadFile $destination $url $true -ProxyToUse $Proxy
    }
}

<#
.SYNOPSIS
Installs cert-manager controllers in the cluster.
.DESCRIPTION
Applies cert-manager YAML manifest, waits for API readiness, and ensures
CRDs are fully established before returning. Throws on failure.
#>
function Install-CertManagerControllers {
    [CmdletBinding()]
    param()

    Write-Log 'Installing cert-manager' -Console
    $certManagerConfig = Get-CertManagerConfig
    (Invoke-Kubectl -Params 'apply', '-f', $certManagerConfig).Output | Write-Log

    Write-Log 'Waiting for cert-manager APIs to be ready, be patient!' -Console
    $certManagerStatus = Wait-ForCertManagerAvailable
    
    if ($certManagerStatus -ne $true) {
        throw "cert-manager is not ready. Please use cmctl.exe to investigate.`nInstallation of 'cert-manager' failed."
    }

    Write-Log '[CertManager] Waiting for cert-manager CRDs to be fully established' -Console
    $crdWaitResult = Invoke-Kubectl -Params 'wait', '--for=condition=Established', 'crd/clusterissuers.cert-manager.io', 'crd/certificates.cert-manager.io', '--timeout=120s'
    if ($crdWaitResult.Success -ne $true) {
        Write-Log "[CertManager] CRD wait output: $($crdWaitResult.Output)" -Console
        $crdStatus = (Invoke-Kubectl -Params 'get', 'crd', 'clusterissuers.cert-manager.io', 'certificates.cert-manager.io', '-o=wide').Output
        Write-Log "[CertManager] CRD status: $crdStatus" -Console
        throw "cert-manager CRDs did not become Established within 120s. CRD status: $crdStatus"
    }
    Write-Log '[CertManager] cert-manager CRDs are established' -Console

    # kubectl caches API discovery and HTTP responses locally. Even after CRDs
    # are Established, the cache will lack cert-manager.io/v1. Clear cache before
    # EACH probe because if the API server discovery hasn't updated yet when kubectl
    # re-fetches, the fresh-but-incomplete response gets cached again.
    Write-Log '[CertManager] Waiting for kubectl to recognize cert-manager CRDs' -Console
    $discoveryReady = $false
    for ($d = 1; $d -le 30; $d++) {
        Clear-KubectlDiscoveryCache
        $probe = Invoke-Kubectl -Params 'get', 'clusterissuers', '--no-headers', '--ignore-not-found'
        if ($probe.Success -eq $true) {
            Write-Log '[CertManager] kubectl can see cert-manager CRDs' -Console
            $discoveryReady = $true
            break
        }
        Write-Log "[CertManager] Discovery probe attempt $d/30 failed, retrying in 2s..." -Console
        Start-Sleep -Seconds 2
    }
    if (-not $discoveryReady) {
        Write-Log '[CertManager] WARNING: kubectl could not discover cert-manager CRDs within 60s' -Console
    }
}

<#
.SYNOPSIS
Initializes CA ClusterIssuer for cert-manager.
.DESCRIPTION
Applies CA ClusterIssuer manifest with retry logic, waits for root certificate creation,
and renews all existing certificates using the new CA.
#>
function Initialize-CACertificateIssuer {
    [CmdletBinding()]
    param()

    Write-Log 'Configuring CA ClusterIssuer' -Console
    $caIssuerConfig = Get-CAIssuerConfig

    $maxRetries = 5
    $retryDelay = 10
    $applied = $false
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        Write-Log "[CertManager] Applying CA issuer manifest (attempt $attempt/$maxRetries)" -Console
        # Clear kubectl cache before each attempt so stale cached discovery
        # responses don't prevent recognition of cert-manager CRD types
        Clear-KubectlDiscoveryCache
        $result = Invoke-Kubectl -Params 'apply', '--server-side', '--force-conflicts', '-f', $caIssuerConfig
        Write-Log "[CertManager] kubectl apply output: $($result.Output)"
        if ($result.Success -eq $true) {
            $applied = $true
            break
        }
        Write-Log "[CertManager] kubectl apply failed (attempt $attempt/$maxRetries): $($result.Output)" -Console
        if ($attempt -lt $maxRetries) {
            Start-Sleep -Seconds $retryDelay
        }
    }

    if (-not $applied) {
        throw "Failed to apply CA issuer manifest after $maxRetries attempts. Last output: $($result.Output)"
    }

    Write-Log 'Waiting for CA root certificate to be created' -Console
    $caCreated = Wait-ForCARootCertificate
    
    if ($caCreated -ne $true) {
        throw "CA root certificate 'ca-issuer-root-secret' not found.`nInstallation of 'cert-manager' failed."
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
    [int]$NumberOfRetries = 30) {
    for (($i = 1); $i -le $NumberOfRetries; $i++) {
        $out = (Invoke-Kubectl -Params '-n', 'cert-manager', 'get', 'secrets', 'ca-issuer-root-secret', '-o=jsonpath="{.metadata.name}"', '--ignore-not-found').Output
        if ($out -match 'ca-issuer-root-secret') {
            Write-Log "'ca-issuer-root-secret' created and ready for use."
            return $true
        }
        Write-Log "Retry {$i}: 'ca-issuer-root-secret' not yet created. Will retry after $SleepDurationInSeconds Seconds" -Console
        Start-Sleep -Seconds $SleepDurationInSeconds
    }

    # Dump diagnostics on failure
    Write-Log '[CertManager] ca-issuer-root-secret was not created. Collecting diagnostics...' -Console
    $certStatus = (Invoke-Kubectl -Params '-n', 'cert-manager', 'get', 'certificates', 'k2s-self-signed-ca', '-o=yaml', '--ignore-not-found').Output
    Write-Log "[CertManager] Certificate resource status: $certStatus" -Console
    $issuerStatus = (Invoke-Kubectl -Params 'get', 'clusterissuers', 'k2s-boot-strapper-issuer', '-o=yaml', '--ignore-not-found').Output
    Write-Log "[CertManager] ClusterIssuer status: $issuerStatus" -Console
    $cmPods = (Invoke-Kubectl -Params '-n', 'cert-manager', 'get', 'pods', '-o=wide').Output
    Write-Log "[CertManager] cert-manager pods: $cmPods" -Console
    $cmEvents = (Invoke-Kubectl -Params '-n', 'cert-manager', 'get', 'events', '--sort-by=.lastTimestamp').Output
    Write-Log "[CertManager] cert-manager events: $cmEvents" -Console

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
        Install-CertManagerControllers
        
        Initialize-CACertificateIssuer
        
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
    return @{
        Name = $Name
        Value = $Value
        Okay = $Value
        Message = if ($Value) { $SuccessMessage } else { $FailureMessage }
    }
}

<#
.SYNOPSIS
Clears the kubectl API discovery cache from disk.
.DESCRIPTION
Deletes the kubectl discovery cache directory (~/.kube/cache/discovery/) so that
subsequent kubectl commands re-fetch the API server's discovery document.
This is required after installing new CRDs because kubectl's cached discovery
has a long TTL and will not pick up newly registered API groups/versions
automatically. Without this, commands like 'kubectl apply' and 'kubectl get'
fail with 'no matches for kind' errors for CRD-based resources.
.EXAMPLE
Clear-KubectlDiscoveryCache
#>
function Clear-KubectlDiscoveryCache {
    [CmdletBinding()]
    param()

    $kubeCacheDir = Join-Path (Join-Path $env:USERPROFILE '.kube') 'cache'
    if (Test-Path $kubeCacheDir) {
        Write-Log '[kubectl] Clearing kubectl cache to pick up newly registered CRDs' -Console
        Remove-Item -Recurse -Force $kubeCacheDir -ErrorAction SilentlyContinue
    }
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
    # Use --server-side to avoid oversized last-applied annotations on large CRDs
    (Invoke-Kubectl -Params 'apply', '--server-side', '-f', $gatewayApiCrds).Output | Write-Log

    # Wait for Gateway CRD to be fully established before clearing cache
    Write-Log '[GatewayAPI] Waiting for Gateway API CRDs to be fully established' -Console
    $gwCrdWait = Invoke-Kubectl -Params 'wait', '--for=condition=Established', 'crd/gateways.gateway.networking.k8s.io', '--timeout=120s'
    if ($gwCrdWait.Success -ne $true) {
        Write-Log "[GatewayAPI] CRD wait output: $($gwCrdWait.Output)" -Console
        Write-Log '[GatewayAPI] WARNING: Gateway API CRDs may not be fully established' -Console
    }

    # Clear stale kubectl discovery cache and verify Gateway type is visible
    Clear-KubectlDiscoveryCache
    Write-Log '[GatewayAPI] Waiting for kubectl discovery cache to include Gateway API CRDs' -Console
    $gwDiscoveryReady = $false
    for ($d = 1; $d -le 15; $d++) {
        $probe = Invoke-Kubectl -Params 'get', 'gateways.gateway.networking.k8s.io', '--no-headers', '--ignore-not-found', '-A'
        if ($probe.Success -eq $true) {
            Write-Log '[GatewayAPI] kubectl discovery cache is up-to-date' -Console
            $gwDiscoveryReady = $true
            break
        }
        Write-Log "[GatewayAPI] Discovery probe attempt $d/15 failed, retrying in 2s..." -Console
        Start-Sleep -Seconds 2
    }
    if (-not $gwDiscoveryReady) {
        Write-Log '[GatewayAPI] WARNING: kubectl discovery cache did not refresh within 30s' -Console
    }
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

    try {
        # Check if cert-manager is installed by probing the namespace
        $certManagerNs = (Invoke-Kubectl -Params 'get', 'namespace', 'cert-manager', '--ignore-not-found').Output
        if (-not (Test-Path $cmctlExe) -or [string]::IsNullOrWhiteSpace($certManagerNs)) {
            $certManagerProp = @{
                Name    = 'IsCertManagerAvailable'
                Value   = $false
                Okay    = $false
                Message = 'The cert-manager is not installed (omitted during addon enablement).'
            }
            $caRootCertificateProp = @{
                Name    = 'IsCaRootCertificateAvailable'
                Value   = $false
                Okay    = $false
                Message = 'The CA root certificate is not available (cert-manager was omitted).'
            }
            return $certManagerProp, $caRootCertificateProp
        }

        $certManagerAvailable = Wait-ForCertManagerAvailable
        $certManagerProp = @{
            Name    = 'IsCertManagerAvailable'
            Value   = $certManagerAvailable
            Okay    = $certManagerAvailable
            Message = if ($certManagerAvailable) { 'The cert-manager API is ready' } else { 'The cert-manager API is not ready. Please use cmctl.exe for further diagnostics.' }
        }

        $caRootCertificateAvailable = Wait-ForCARootCertificate
        $caRootCertificateProp = @{
            Name    = 'IsCaRootCertificateAvailable'
            Value   = $caRootCertificateAvailable
            Okay    = $caRootCertificateAvailable
            Message = if ($caRootCertificateAvailable) { 'The CA root certificate is available' } else { "The CA root certificate is not available ('ca-issuer-root-secret' not created)." }
        }

        return $certManagerProp, $caRootCertificateProp
    }
    catch {
        Write-Log "[CertManager] Error checking cert-manager status: $($_.Exception.Message)" -Console
        $certManagerProp = @{
            Name    = 'IsCertManagerAvailable'
            Value   = $false
            Okay    = $false
            Message = 'The cert-manager is not installed (omitted during addon enablement).'
        }
        $caRootCertificateProp = @{
            Name    = 'IsCaRootCertificateAvailable'
            Value   = $false
            Okay    = $false
            Message = 'The CA root certificate is not available (cert-manager was omitted).'
        }
        return $certManagerProp, $caRootCertificateProp
    }
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

Export-ModuleMember -Function Enable-AddonFromConfig, Get-EnabledAddons, Add-AddonToSetupJson, Update-AddonVersionInSetupJson, Remove-AddonFromSetupJson,
Install-DebianPackages, Get-DebianPackageAvailableOffline, Test-IsAddonEnabled, Invoke-AddonsHooks, Copy-ScriptsToHooksDir,
Remove-ScriptsFromHooksDir, Get-AddonConfig, Backup-Addons, Restore-Addons, Get-AddonStatus, Find-AddonManifests,
Get-ErrCodeAddonAlreadyDisabled, Get-ErrCodeAddonAlreadyEnabled, Get-ErrCodeAddonEnableFailed, Get-ErrCodeAddonNotFound, Get-ErrCodeInvalidParameter,
Add-HostEntries, Add-CoreDNSHostEntry, Remove-CoreDNSHostEntry, Get-AddonsConfig, Update-Addons, Update-IngressForAddon, Test-NginxIngressControllerAvailability, Test-TraefikIngressControllerAvailability,
Test-KeyCloakServiceAvailability, Enable-IngressAddon, Remove-IngressForTraefik, Remove-IngressForNginx, Get-AddonProperties, Get-IngressNginxConfigDirectory,
Update-IngressForTraefik, Update-IngressForNginx, Get-IngressNginxSecureConfig, Get-IngressTraefikConfig, Enable-StorageAddon, Get-AddonNameFromFolderPath, Resolve-AddonImportPath,
Test-LinkerdServiceAvailability, Test-TrustManagerServiceAvailability, Test-KeyCloakServiceAvailability, Get-IngressTraefikSecureConfig, Write-BrowserWarningForUser,
Get-ImagesFromYamlFiles, Get-ImagesFromYaml, Remove-VersionlessImages, Get-IngressNginxGatewayConfig, Remove-IngressForNginxGateway, Update-IngressForNginxGateway, Test-NginxGatewayAvailability, Get-IngressNginxGatewaySecureConfig,
Get-CertManagerConfig, Get-CAIssuerConfig, Install-CmctlCli, Install-CertManagerControllers, Initialize-CACertificateIssuer, Import-CACertificateToWindowsStore, Enable-CertManager, Uninstall-CertManager, New-AddonStatusProperty, Get-CertManagerStatusProperties, Wait-ForCertManagerAvailable,
Get-GatewayApiCrdsConfig, Install-GatewayApiCrds, Uninstall-GatewayApiCrds, Assert-IngressTlsCertificate, Wait-ForK8sSecret, New-BackendCACertConfigMap,
Clear-KubectlDiscoveryCache