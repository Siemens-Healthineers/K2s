// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package node

import (
	"fmt"
	"log/slog"

	bos "os"

	"github.com/siemens-healthineers/k2s/internal/core/node/ssh"
)

func Exec(command string, connectionOptions ssh.ConnectionOptions) error {
	sshClient, err := ssh.Connect(connectionOptions)
	if err != nil {
		return fmt.Errorf("failed to dial SSH: %w", err)
	}
	defer func() {
		slog.Debug("Closing SSH client")
		if err := sshClient.Close(); err != nil {
			slog.Error("failed to close SSH client", "error", err)
		}
	}()

	session, err := sshClient.NewSession()
	if err != nil {
		return fmt.Errorf("failed to create SSH session: %w", err)
	}

	session.Stdout = bos.Stdout
	session.Stderr = bos.Stdout

	// Session.Run() implicitly closes the session afterwards
	if err := session.Run(command); err != nil {
		return fmt.Errorf("failed to run command: %w", err)
	}
	return nil
}
