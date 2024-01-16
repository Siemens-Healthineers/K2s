// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package k2s

import (
	"context"
)

type CliExecutor interface {
	ExecOrFail(ctx context.Context, cliPath string, cliArgs ...string) string
}

type K2sCliRunner struct {
	cliPath     string
	cliExecutor CliExecutor
}

func NewCli(cliPath string, cliExecutor CliExecutor) *K2sCliRunner {
	return &K2sCliRunner{
		cliPath:     cliPath,
		cliExecutor: cliExecutor,
	}
}

// convenience wrapper around k2s.exe
func (s *K2sCliRunner) Run(ctx context.Context, cliArgs ...string) string {
	return s.cliExecutor.ExecOrFail(ctx, s.cliPath, cliArgs...)
}
