// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package kubectl

import (
	"fmt"
	"log/slog"
	"path/filepath"

	"github.com/siemens-healthineers/k2s/internal/core/users/common"
)

type kubectl struct {
	exec common.CmdExecutor
	path string
}

func NewKubectl(installDir string, cmdExecutor common.CmdExecutor) *kubectl {
	path := filepath.Join(installDir, "bin\\kube\\kubectl.exe")

	return &kubectl{
		exec: cmdExecutor,
		path: path,
	}
}

func (k *kubectl) Exec(params ...string) error {
	slog.Debug("Executing kubectl", "params-len", len(params))

	if err := k.exec.ExecuteCmd(k.path, params...); err != nil {
		return fmt.Errorf("error while executing kubectl: %w", err)
	}
	return nil
}
