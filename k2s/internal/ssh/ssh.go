// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package ssh

import (
	"fmt"
	"log/slog"
)

type ssh struct {
	exec    cmdExecutor
	keyPath string
	remote  string
}

func NewSsh(cmdExecutor cmdExecutor) *ssh {
	return &ssh{exec: cmdExecutor}
}

func (ssh *ssh) SetConfig(sshKeyPath string, remoteUser string, remoteHost string) {
	slog.Debug("Setting SSH config", "key-path", sshKeyPath, "user", remoteUser, "host", remoteHost)

	ssh.keyPath = sshKeyPath
	ssh.remote = fmt.Sprintf("%s@%s", remoteUser, remoteHost)
}

func (ssh *ssh) Exec(cmd string) error {
	slog.Debug("Exec SSH cmd", "cmd", cmd, "remote", ssh.remote)

	if err := ssh.exec.ExecuteCmd("ssh.exe", "-n", "-o", "StrictHostKeyChecking=no", "-i", ssh.keyPath, ssh.remote, cmd); err != nil {
		return fmt.Errorf("could not exec SSH cmd '%s': %w", cmd, err)
	}
	return nil
}

func (ssh *ssh) ScpToRemote(source string, target string) error {
	slog.Debug("Copying to target", "target-path", target)

	scpTarget := ssh.toRemotePath(target)

	return ssh.scp(source, scpTarget)
}

func (ssh *ssh) ScpFromRemote(source string, target string) error {
	slog.Debug("Copying from source", "source-path", source)

	scpSource := ssh.toRemotePath(source)

	return ssh.scp(scpSource, target)
}

func (ssh *ssh) toRemotePath(path string) string {
	return fmt.Sprintf("%s:%s", ssh.remote, path)
}

func (ssh *ssh) scp(source string, target string) error {
	slog.Debug("Copying via SCP", "source-path", source, "target-path", target)

	if err := ssh.exec.ExecuteCmd("scp.exe", "-o", "StrictHostKeyChecking=no", "-r", "-i", ssh.keyPath, source, target); err != nil {
		return fmt.Errorf("could not copy '%s' to '%s' via SCP: %w", source, target, err)
	}
	return nil
}
