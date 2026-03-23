// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build linux

package ssh

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"

	contracts "github.com/siemens-healthineers/k2s/internal/contracts/ssh"
)

func ConnectInteractively(options contracts.ConnectionOptions) error {
	timeoutOption := fmt.Sprintf("ConnectTimeout=%d", int(options.Timeout.Seconds()))
	port := fmt.Sprintf("%d", options.Port)
	remote := fmt.Sprintf("%s@%s", options.RemoteUser, options.IpAddress)

	cmd := exec.Command("ssh", "-tt", "-o", "StrictHostKeyChecking=no", "-o", timeoutOption, "-i", options.SshPrivateKeyPath, "-p", port, remote)

	slog.Debug("Executing ssh", "command", cmd.String())

	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("failed to start ssh: %w", err)
	}

	if err := cmd.Wait(); err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			exitCode := exitErr.ExitCode()
			if exitCode == 255 {
				return fmt.Errorf("failed to execute ssh: %w", err)
			}
			slog.Debug("failed to execute ssh", "exit-code", exitErr.ExitCode())
			return nil
		}
		return fmt.Errorf("failed to wait for ssh execution: %w", err)
	}
	return nil
}
