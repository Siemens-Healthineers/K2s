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

	K2sUsersPrefix = "k2s-"
	K2sUserGroup   = K2sUsersPrefix + "users"
)
