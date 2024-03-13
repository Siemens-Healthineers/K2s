// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package params

const (
	OutputFlagName      = "output"
	OutputFlagShorthand = "o"
	OutputFlagUsage     = "Show all logs in terminal"

	AdditionalHooksDirFlagName  = "additional-hooks-dir"
	AdditionalHooksDirFlagUsage = "Directory containing additional hooks to be executed"

	DeleteFilesFlagName      = "delete-files-for-offline-installation"
	DeleteFilesFlagShorthand = "d"
	DeleteFilesFlagUsage     = "After an online installation delete the files that are needed for an offline installation"

	ForceOnlineInstallFlagName      = "force-online-installation"
	ForceOnlineInstallFlagShorthand = "f"
	ForceOnlineInstallFlagUsage     = "Force the online installation"

	AutouseCachedVSwitchFlagName  = "autouse-cached-vswitch"
	AutouseCachedVSwitchFlagUsage = "Automatically utilizes the cached vSwitch 'cbr0' and 'KubeSwitch' for cluster connectivity through the host machine"

	CacheVSwitchFlagName  = "cache-vswitch"
	CacheVSwitchFlagUsage = "Cache vswitches 'cbr0' and 'KubeSwitch' for cluster connectivity through the host machine."
)
