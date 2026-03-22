// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build linux

package start

import (
	"log/slog"
	"strconv"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/internal/setuporchestration"
	"github.com/spf13/cobra"
)

// startLinux handles K2s start natively on a Linux host using systemd.
func startLinux(cmd *cobra.Command) error {
	outputFlag, _ := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	additionalHooksDir := cmd.Flags().Lookup(common.AdditionalHooksDirFlagName).Value.String()

	slog.Info("Starting K2s via native Linux orchestrator")

	orchestrator := setuporchestration.NewOrchestrator(nil)

	cfg := setuporchestration.StartConfig{
		ShowLogs:           outputFlag,
		AdditionalHooksDir: additionalHooksDir,
	}

	return orchestrator.Start(cfg)
}
