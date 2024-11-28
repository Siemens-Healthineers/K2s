// SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package k8s

import (
	"context"
	"path/filepath"
)

type CliExecutor interface {
	ExecOrFail(ctx context.Context, cliPath string, cliArgs ...string) string
}

type Kubectl struct {
	cliPath     string
	cliExecutor CliExecutor
}

func NewCli(cliExecutor CliExecutor, rootDir string) *Kubectl {
	cliPath := filepath.Join(rootDir, "bin", "kube", "kubectl.exe")

	return &Kubectl{
		cliPath:     cliPath,
		cliExecutor: cliExecutor,
	}
}

func (k *Kubectl) Run(ctx context.Context, args ...string) string {
	return k.cliExecutor.ExecOrFail(ctx, k.cliPath, args...)
}
