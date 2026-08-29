// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package definitions

import "time"

const (
	// TODO: configure centrally in config.json eventually
	SSHPrivateKeyName        = "id_rsa"
	SSHSubDirName            = "k2s"
	SSHRemoteUser            = "remote"
	SSHDefaultPort    uint16 = 22
	SSHDefaultTimeout        = 30 * time.Second

	KubeconfigName = "config"

	SetupNameK2s             = "k2s"
	SetupNameBuildOnlyEnv    = "BuildOnlyEnv"
	K2sRuntimeConfigFileName = "setup.json"
	SetupCorruptedKey        = "Corrupted"
	LegacyClusterName        = "kubernetes"

	// SetupConfigDirEnvVar overrides the K2s setup config directory ('configDir.k2s')
	// for child processes (e.g. the PowerShell upgrade scripts). When set, it takes
	// precedence over the 'configDir.k2s' entry of the running package's cfg/config.json.
	// It is used during 'k2s system upgrade' to point the upgrade scripts to the setup
	// config of the already installed K2s, which may reside in a customized location.
	SetupConfigDirEnvVar = "K2S_SETUP_CONFIG_DIR"

	K2sUsersPrefix = "k2s-"
	K2sUserGroup   = K2sUsersPrefix + "users"
)
