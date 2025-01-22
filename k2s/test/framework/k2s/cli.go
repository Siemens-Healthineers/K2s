// SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package k2s

import (
	"context"
)

type ExitCode int

const (
	ExitCodeSuccess ExitCode = 0
	ExitCodeFailure ExitCode = 1
)

type CliExecutor interface {
	Exec(ctx context.Context, cliPath string, cliArgs ...string) (string, int)
	ExecOrFail(ctx context.Context, cliPath string, cliArgs ...string) string
	ExecOrFailWithExitCode(ctx context.Context, cliPath string, expectedExitCode int, cliArgs ...string) string
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

// RunOrFail is a convenience wrapper around k2s.exe
func (s *K2sCliRunner) RunOrFail(ctx context.Context, cliArgs ...string) string {
	return s.cliExecutor.ExecOrFail(ctx, s.cliPath, cliArgs...)
}

func (k *K2sCliRunner) RunWithExitCode(ctx context.Context, expectedExitCode ExitCode, args ...string) string {
	return k.cliExecutor.ExecOrFailWithExitCode(ctx, k.cliPath, int(expectedExitCode), args...)
}

func (s *K2sCliRunner) Run(ctx context.Context, cliArgs ...string) (string, int) {
	return s.cliExecutor.Exec(ctx, s.cliPath, cliArgs...)
}

// Path returns the absolute file path of the k2s.exe
func (s *K2sCliRunner) Path() string {
	return s.cliPath
}
