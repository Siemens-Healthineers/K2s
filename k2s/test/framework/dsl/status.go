// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package dsl

import (
	"context"

	"github.com/siemens-healthineers/k2s/test/framework/k2s"
)

func (k *K2s) RunStatusCmd(ctx context.Context) *K2sCmdResult {
	output, exitCode := k.suite.K2sCli().Run(ctx, "status")

	return &K2sCmdResult{
		output:   output,
		exitCode: k2s.ExitCode(exitCode),
	}
}
