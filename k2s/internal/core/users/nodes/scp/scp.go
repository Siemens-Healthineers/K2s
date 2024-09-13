// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package scp

import (
	"fmt"
	"log/slog"

	"github.com/siemens-healthineers/k2s/internal/core/users/common"
)

type scp struct {
	exec    common.CmdExecutor
	keyPath string
	remote  string
}

func NewScp(cmdExecutor common.CmdExecutor, keyPath string, remoteUser string) *scp {
	return &scp{
		exec:    cmdExecutor,
		keyPath: keyPath,
		remote:  remoteUser,
	}
}

func (scp *scp) CopyToRemote(source string, target string) error {
	slog.Debug("Copying to target", "target-path", target)

	scpTarget := scp.toRemotePath(target)

	return scp.scp(source, scpTarget)
}

func (scp *scp) CopyFromRemote(source string, target string) error {
	slog.Debug("Copying from source", "source-path", source)

	scpSource := scp.toRemotePath(source)

	return scp.scp(scpSource, target)
}

func (scp *scp) toRemotePath(path string) string {
	return fmt.Sprintf("%s:%s", scp.remote, path)
}

func (scp *scp) scp(source string, target string) error {
	slog.Debug("Copying via SCP", "source-path", source, "target-path", target)

	if err := scp.exec.ExecuteCmd("scp.exe", "-o", "StrictHostKeyChecking=no", "-r", "-i", scp.keyPath, source, target); err != nil {
		return fmt.Errorf("could not copy '%s' to '%s' via SCP: %w", source, target, err)
	}
	return nil
}
