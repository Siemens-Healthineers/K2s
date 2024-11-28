// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package ssh

import (
	"fmt"
	"log/slog"
	"os"
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
	SshPubKeyName        = sshKeyName + ".pub"
	DefaultPort   uint16 = 22

	sshKeyName    = "id_rsa"
	sshSubDirName = "kubemaster" // TODO: this will change to a more generic sub dir name in the near future
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
