// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package reset

import (
	"errors"
	"log/slog"
	"path/filepath"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"
	"github.com/siemens-healthineers/k2s/internal/powershell"

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
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	resetSystemCommand, err := buildResetSystemCmd()
	if err != nil {
		return err
	}

	slog.Debug("PS command created", "command", resetSystemCommand)

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	config, err := setupinfo.ReadConfig(context.Config().Host().K2sConfigDir())
	if err != nil {
		if !errors.Is(err, setupinfo.ErrSystemInCorruptedState) && !errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return err
		}
	}

	if config.LinuxOnly {
		return common.CreateFuncUnavailableForLinuxOnlyCmdFailure()
	}

	err = powershell.ExecutePs(resetSystemCommand, common.NewPtermWriter())
	if err != nil {
		return err
	}

	cmdSession.Finish()

	return nil
}

func buildResetSystemCmd() (string, error) {
	resetSystemCommand := utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "system", "reset", "Reset-System.ps1"))

	return resetSystemCommand, nil
}
