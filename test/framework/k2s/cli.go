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

type k2sCliRunner struct {
	cliPath     string
	cliExecutor CliExecutor
}

func NewCli(cliPath string, cliExecutor CliExecutor) *k2sCliRunner {
	return &k2sCliRunner{
		cliPath:     cliPath,
		cliExecutor: cliExecutor,
	}
}

// convenience wrapper around k2s.exe
func (s *k2sCliRunner) Run(ctx context.Context, cliArgs ...string) string {
	return s.cliExecutor.ExecOrFail(ctx, s.cliPath, cliArgs...)
}
