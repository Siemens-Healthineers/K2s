// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package dsl

import (
	"context"

	"github.com/siemens-healthineers/k2s/internal/cli"
)

func (k2s *K2s) ShowStatus(ctx context.Context) *K2sCmdResult {
	return k2s.runCmd(ctx, "status")
}

func (k2s *K2s) Start(ctx context.Context) *K2sCmdResult {
	return k2s.runCmd(ctx, "start")
}

func (k2s *K2s) AddNode(ctx context.Context) *K2sCmdResult {
	return k2s.runCmd(ctx, "node", "add", "-i", "ip", "-u", "user")
}

func (k2s *K2s) RemoveNode(ctx context.Context) *K2sCmdResult {
	return k2s.runCmd(ctx, "node", "remove", "-m", "machine")
}

func (k2s *K2s) RemoveImage(ctx context.Context) *K2sCmdResult {
	return k2s.runCmd(ctx, "image", "rm")
}

func (k2s *K2s) ShowAddonStatus(ctx context.Context, addon, implementation string) *K2sCmdResult {
	return k2s.runCmd(ctx, "addons", "status", addon, implementation)
}

func (k2s *K2s) EnableAddon(ctx context.Context, addon, implementation string) *K2sCmdResult {
	return k2s.runCmd(ctx, "addons", "enable", addon, implementation)
}

func (k2s *K2s) DisableAddon(ctx context.Context, addon, implementation string) *K2sCmdResult {
	cliArgs := []string{"addons", "disable", addon, implementation}

	if addon == "storage" {
		cliArgs = append(cliArgs, "-f")
	}

	return k2s.runCmd(ctx, cliArgs...)
}

func (k2s *K2s) runCmd(ctx context.Context, cliArgs ...string) *K2sCmdResult {
	output, exitCode := k2s.suite.K2sCli().Exec(ctx, cliArgs...)

	return &K2sCmdResult{
		output:   output,
		exitCode: cli.ExitCode(exitCode),
	}
}
