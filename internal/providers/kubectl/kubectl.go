// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package kubectl

import (
	"fmt"
	"log/slog"
	"path/filepath"

	"github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/os"
)

type Kubectl struct {
	kubectlCmd string
}

func NewKubectl(hostConfig *config.HostConfig) *Kubectl {
	return &Kubectl{
		kubectlCmd: filepath.Join(hostConfig.K2sInstallDir(), "bin\\kube\\kubectl.exe"),
	}
}

func (k *Kubectl) Exec(args ...string) error {
	slog.Debug("Executing kubectl command")

	cmd := os.NewCmd(k.kubectlCmd).
		WithArgs(args...).
		WithStdOutWriter(slog.Info).
		WithStdErrWriter(slog.Error)

	if err := cmd.Exec(); err != nil {
		return fmt.Errorf("failed to execute kubectl command: %w", err)
	}
	return nil
}
