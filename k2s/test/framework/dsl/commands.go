// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package dsl

import (
	"context"

	"github.com/siemens-healthineers/k2s/test/framework/k2s"
)

func (k *K2s) RunStatusCmd(ctx context.Context) *K2sCmdResult {
	return k.runCmd(ctx, "status")
}

func (k *K2s) RunStartCmd(ctx context.Context) *K2sCmdResult {
	return k.runCmd(ctx, "start")
}

func (k *K2s) RunNodeAddCmd(ctx context.Context) *K2sCmdResult {
	return k.runCmd(ctx, "node", "add", "-i", "ip", "-u", "user")
}

func (k *K2s) RunNodeRemoveCmd(ctx context.Context) *K2sCmdResult {
	return k.runCmd(ctx, "node", "remove", "-m", "machine")
}

func (k *K2s) RunImageRmCmd(ctx context.Context) *K2sCmdResult {
	return k.runCmd(ctx, "image", "rm")
}

func (k *K2s) RunAddonsStatusCmd(ctx context.Context, addon, implementation string) *K2sCmdResult {
	return k.runCmd(ctx, "addons", "status", addon, implementation)
}

func (k *K2s) RunAddonsEnableCmd(ctx context.Context, addon, implementation string) *K2sCmdResult {
	return k.runCmd(ctx, "addons", "enable", addon, implementation)
}

func (k *K2s) RunAddonsDisableCmd(ctx context.Context, addon, implementation string) *K2sCmdResult {
	return k.runCmd(ctx, "addons", "disable", addon, implementation)
}

func (k *K2s) runCmd(ctx context.Context, cliArgs ...string) *K2sCmdResult {
	output, exitCode := k.suite.K2sCli().Run(ctx, cliArgs...)

	return &K2sCmdResult{
		output:   output,
		exitCode: k2s.ExitCode(exitCode),
	}
}
