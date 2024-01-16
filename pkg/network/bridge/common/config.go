// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package common

// Command line options.
const (
	// Operating environment.
	OptEnvironment      = "environment"
	OptEnvironmentAlias = "e"
	OptEnvironmentAzure = "azure"
	OptEnvironmentMAS   = "mas"

	// Logging level.
	OptLogLevel      = "log-level"
	OptLogLevelAlias = "l"
	OptLogLevelInfo  = "info"
	OptLogLevelDebug = "debug"

	// Logging target.
	OptLogTarget       = "log-target"
	OptLogTargetAlias  = "t"
	OptLogTargetSyslog = "syslog"
	OptLogTargetStderr = "stderr"
	OptLogTargetFile   = "logfile"

	// IPAM query URL.
	OptIpamQueryUrl      = "ipam-query-url"
	OptIpamQueryUrlAlias = "u"

	// IPAM query interval.
	OptIpamQueryInterval      = "ipam-query-interval"
	OptIpamQueryIntervalAlias = "i"

	// Version.
	OptVersion      = "version"
	OptVersionAlias = "v"

	// Help.
	OptHelp      = "help"
	OptHelpAlias = "h"
)
