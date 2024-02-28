// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package params

const (
	VerbosityFlagName      = "v"
	VerbosityFlagShorthand = "v"
	VerbosityFlagUsage     = "number for the log level verbosity, e.g --v=8"

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

	TryUseCacheK2sVSwitchesFlagName  = "try-use-cached-k2s-vswitches"
	TryUseCacheK2sVSwitchesFlagUsage = "Try to use Cached k2s vSwitches"

	CacheK2sVSwitchesFlagName  = "cache-k2s-vswitches"
	CacheK2sVSwitchesFlagUsage = "Cache K2s vswitches"
)
