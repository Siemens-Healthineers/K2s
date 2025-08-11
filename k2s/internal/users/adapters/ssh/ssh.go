// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package ssh

import (
	contracts "github.com/siemens-healthineers/k2s/internal/contracts/ssh"
	"github.com/siemens-healthineers/k2s/internal/providers/ssh"
)

type SSHProvider struct {
	connectionOptions contracts.ConnectionOptions
}

func NewSSHProvider(connectionOptions contracts.ConnectionOptions) *SSHProvider {
	return &SSHProvider{
		connectionOptions: connectionOptions,
	}
}

func (*SSHProvider) CreateKeyPair(privateKeyPath, publicKeyComment string) (publicKeyPath string, err error) {
	return ssh.CreateKeyPair(privateKeyPath, publicKeyComment)
}

func (s *SSHProvider) Copy(copyOptions contracts.CopyOptions) error {
	return ssh.Copy(copyOptions, s.connectionOptions)
}

func (s *SSHProvider) Move(copyOptions contracts.CopyOptions) error {
	return ssh.Move(copyOptions, s.connectionOptions)
}

func (s *SSHProvider) Exec(command string) error {
	return ssh.Exec(command, s.connectionOptions)
}
