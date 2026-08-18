// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package ssh

import (
	"path/filepath"

	"github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/contracts/users"
	"github.com/siemens-healthineers/k2s/internal/definitions"
	"github.com/siemens-healthineers/k2s/internal/host"
)

type KeyPathResolver struct {
	sshConfig *config.SSHConfig
}

func NewKeyPathResolver(sshConfig *config.SSHConfig) *KeyPathResolver {
	return &KeyPathResolver{
		sshConfig: sshConfig,
	}
}

func (k *KeyPathResolver) ResolvePrivateKeyPath(user *users.OSUser) string {
	sshDir := host.ResolveTildePrefix(k.sshConfig.RelativeDir(), user.HomeDir())

	return filepath.Join(sshDir, definitions.SSHSubDirName, definitions.SSHPrivateKeyName)
}
