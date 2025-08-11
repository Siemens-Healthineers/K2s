// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package reset

import (
	"errors"
	"path/filepath"
	"strconv"

	"github.com/spf13/cobra"

	cconfig "github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/siemens-healthineers/k2s/internal/terminal"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
)

var resetNetworkCmd = &cobra.Command{
	Use:   "network",
	Short: "Reset network (restart required)",
	RunE:  resetNetwork,
}

const (
	forceFlagName = "force"
)

func init() {
	resetNetworkCmd.Flags().BoolP("force", "f", false, "force network reset")
	resetNetworkCmd.Flags().SortFlags = false
	resetNetworkCmd.Flags().PrintDefaults()
}

func resetNetwork(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	runtimeConfig, err := config.ReadRuntimeConfig(context.Config().Host().K2sSetupConfigDir())
	if err != nil {
		if errors.Is(err, cconfig.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
	}
	if err == nil && runtimeConfig.InstallConfig().SetupName() != "" {
		terminal.NewTerminalPrinter().PrintInfofln(
			"'%s' setup is installed, please uninstall with 'k2s uninstall' first or reset system with 'k2s system reset' and re-run the 'k2s system reset network' command afterwards.",
			runtimeConfig.InstallConfig().SetupName())
		return nil
	}

	resetNetworkCommand := utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "system", "reset", "network", "Reset-Network.ps1"))

	params := []string{}

	forceFlag, err := strconv.ParseBool(cmd.Flags().Lookup(forceFlagName).Value.String())
	if err != nil {
		return err
	}

	if forceFlag {
		params = append(params, " -Force")
	}

	outputFlag, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return err
	}

	if outputFlag {
		params = append(params, " -ShowLogs")
	}

	cmdResult, err := powershell.ExecutePsWithStructuredResult[*common.CmdResult](resetNetworkCommand, "CmdResult", common.NewPtermWriter(), params...)

	if err != nil {
		return err
	}

	if cmdResult.Failure != nil {
		return cmdResult.Failure
	}

	cmdSession.Finish()

	return nil
}
