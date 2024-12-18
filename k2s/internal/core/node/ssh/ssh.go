// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package ssh

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"golang.org/x/crypto/ssh"
)

type ConnectionOptions struct {
	IpAddress  string
	Port       uint16
	RemoteUser string
	SshKeyPath string
	Timeout    time.Duration
}

const (
	SshPubKeyName         = sshKeyName + ".pub"
	DefaultPort    uint16 = 22
	DefaultTimeout        = 30 * time.Second

	sshKeyName    = "id_rsa"
	sshSubDirName = "k2s"
)

func SshKeyPath(sshDir string) string {
	return filepath.Join(sshDir, sshSubDirName, sshKeyName)
}

func Connect(options ConnectionOptions) (*ssh.Client, error) {
	slog.Debug("Connecting via SSH", "ip", options.IpAddress, "user", options.RemoteUser, "key", options.SshKeyPath, "timeout", options.Timeout)

	key, err := os.ReadFile(options.SshKeyPath)
	if err != nil {
		return nil, fmt.Errorf("failed to read private SSH key: %w", err)
	}

	signer, err := ssh.ParsePrivateKey(key)
	if err != nil {
		return nil, fmt.Errorf("failed to parse private SSH key: %w", err)
	}

	clientConfig := &ssh.ClientConfig{
		User: options.RemoteUser,
		Auth: []ssh.AuthMethod{
			ssh.PublicKeys(signer),
		},
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         options.Timeout,
	}

	address := fmt.Sprintf("%s:%d", options.IpAddress, options.Port)
	sshClient, err := ssh.Dial("tcp", address, clientConfig)
	if err != nil {
		return nil, fmt.Errorf("failed to connect via SSH to '%s': %w", address, err)
	}

	slog.Debug("Connected via SSH", "ip", options.IpAddress)
	return sshClient, nil
}

func ConnectInteractively(options ConnectionOptions) error {
	timeoutOption := fmt.Sprintf("ConnectTimeout=%d", int(options.Timeout.Seconds()))
	port := fmt.Sprintf("%d", options.Port)
	remote := fmt.Sprintf("%s@%s", options.RemoteUser, options.IpAddress)

	cmd := exec.Command("ssh.exe", "-tt", "-o", "StrictHostKeyChecking=no", "-o", timeoutOption, "-i", options.SshKeyPath, "-p", port, remote)

	slog.Debug("Executing ssh.exe", "command", cmd.String())

	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("failed to start ssh.exe: %w", err)
	}

	if err := cmd.Wait(); err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			exitCode := exitErr.ExitCode()
			if exitCode == 255 {
				return fmt.Errorf("failed to execute ssh.exe: %w", err)
			}
			slog.Debug("failed to execute ssh.exe", "exit-code", exitErr.ExitCode())
			return nil
		}
		return fmt.Errorf("failed to wait for ssh.exe execution: %w", err)
	}
	return nil
}
