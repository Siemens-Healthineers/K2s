// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare AG
// SPDX-License-Identifier:   MIT

// TODO: consolidate with k2s/internal/core/node/ssh package
package ssh

import (
	"fmt"
	"log/slog"

	"github.com/siemens-healthineers/k2s/internal/core/users/common"
)

type ssh struct {
	exec    common.CmdExecutor
	keyPath string
	remote  string
}

func NewSsh(cmdExecutor common.CmdExecutor, keyPath, remoteUser string) *ssh {
	return &ssh{
		exec:    cmdExecutor,
		keyPath: keyPath,
		remote:  remoteUser,
	}
}

func (ssh *ssh) Exec(cmd string) error {
	slog.Debug("Exec SSH cmd", "cmd", cmd, "remote", ssh.remote)

	if err := ssh.exec.ExecuteCmd("ssh.exe", "-n", "-o", "StrictHostKeyChecking=no", "-i", ssh.keyPath, ssh.remote, cmd); err != nil {
		return fmt.Errorf("could not exec SSH cmd '%s': %w", cmd, err)
	}
	return nil
}
