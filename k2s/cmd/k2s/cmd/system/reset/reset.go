// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package reset

import (
	"errors"
	"log/slog"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/siemens-healthineers/k2s/internal/setupinfo"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils/psexecutor"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/spf13/cobra"
)

var ResetCmd = &cobra.Command{
	Use:   "reset",
	Short: "Reset options",
	RunE:  resetSystem,
}

func init() {
	ResetCmd.AddCommand(resetNetworkCmd)
	ResetCmd.Flags().SortFlags = false
	ResetCmd.Flags().PrintDefaults()
}

func resetSystem(cmd *cobra.Command, args []string) error {
	resetSystemCommand, err := buildResetSystemCmd(cmd)
	if err != nil {
		return err
	}

	slog.Debug("PS command created", "command", resetSystemCommand)

	configDir := cmd.Context().Value(common.ContextKeyConfigDir).(string)
	config, err := setupinfo.LoadConfig(configDir)
	psVersion := powershell.DefaultPsVersions
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			slog.Info("Setup not installed, falling back to default PowerShell version", "error", err, "version", psVersion)
		}
		return err
	} else {
		psVersion = powershell.DeterminePsVersion(config)
	}

	duration, err := psexecutor.ExecutePowershellScript(resetSystemCommand, psexecutor.ExecOptions{PowerShellVersion: psVersion})
	if err != nil {
		return err
	}

	common.PrintCompletedMessage(duration, "system reset")

	return nil
}

func buildResetSystemCmd(cmd *cobra.Command) (string, error) {
	resetSystemCommand := utils.FormatScriptFilePath(utils.InstallDir() + "\\smallsetup\\helpers\\ResetSystem.ps1")

	return resetSystemCommand, nil
}
