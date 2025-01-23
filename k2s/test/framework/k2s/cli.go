// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
// SPDX-License-Identifier: MIT

package k2s

import (
	"context"

	"github.com/siemens-healthineers/k2s/test/framework/k2s/addons"
	"github.com/siemens-healthineers/k2s/test/framework/k2s/cli"
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

func (k *K2sCliRunner) RunWithExitCode(ctx context.Context, expectedExitCode cli.ExitCode, args ...string) string {
	return k.cliExecutor.ExecOrFailWithExitCode(ctx, k.cliPath, int(expectedExitCode), args...)
}

func (s *K2sCliRunner) Run(ctx context.Context, cliArgs ...string) (string, int) {
	return s.cliExecutor.Exec(ctx, s.cliPath, cliArgs...)
}

// Path returns the absolute file path of the k2s.exe
func (s *K2sCliRunner) Path() string {
	return s.cliPath
}

// wrapper around k2s.exe to retrieve and parse the addons status
func (r *K2sCliRunner) GetAddonsStatus(ctx context.Context) *addons.AddonsStatus {
	output := r.RunOrFail(ctx, "addons", "ls", "-o", "json")

	return unmarshalStatus[addons.AddonsStatus](output)
}
