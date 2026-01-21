// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package ssh

import (
	"fmt"
	"log/slog"
	"os"

	contracts "github.com/siemens-healthineers/k2s/internal/contracts/ssh"
)

func Exec(command string, connectionOptions contracts.ConnectionOptions) error {
	sshClient, err := Connect(connectionOptions)
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

	if connectionOptions.StdOutWriter != nil {
		session.Stdout = connectionOptions.StdOutWriter
	} else {
		session.Stdout = os.Stdout
	}
	session.Stderr = os.Stdout

	// Session.Run() implicitly closes the session afterwards
	if err := session.Run(command); err != nil {
		return fmt.Errorf("failed to run command: %w", err)
	}
	return nil
}
