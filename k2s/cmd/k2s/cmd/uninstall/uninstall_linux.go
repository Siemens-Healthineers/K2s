// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build linux

package uninstall

import (
	"log/slog"
	"strconv"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/internal/host"
	"github.com/siemens-healthineers/k2s/internal/setuporchestration"
	"github.com/spf13/cobra"
)

// uninstallLinux handles K2s uninstall natively on a Linux host.
func uninstallLinux(cmd *cobra.Command) error {
	skipPurgeFlag, _ := strconv.ParseBool(cmd.Flags().Lookup(skipPurge).Value.String())
	outputFlag, _ := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	additionalHooksDir := cmd.Flags().Lookup(common.AdditionalHooksDirFlagName).Value.String()
	deleteFiles, _ := strconv.ParseBool(cmd.Flags().Lookup(common.DeleteFilesFlagName).Value.String())

	slog.Info("Uninstalling K2s via native Linux orchestrator")

	orchestrator := setuporchestration.NewOrchestrator(nil)

	cfg := setuporchestration.UninstallConfig{
		ShowLogs:                          outputFlag,
		SkipPurge:                         skipPurgeFlag,
		DeleteFilesForOfflineInstallation: deleteFiles,
		AdditionalHooksDir:                additionalHooksDir,
		ConfigDir:                         host.K2sConfigDir(),
	}

	return orchestrator.Uninstall(cfg)
}
