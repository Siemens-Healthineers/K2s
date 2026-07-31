// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package reset

import (
	"errors"
	"strconv"

	"github.com/spf13/cobra"

	cconfig "github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/provider"
	"github.com/siemens-healthineers/k2s/internal/terminal"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
)

var resetNetworkCmd = &cobra.Command{
	Use:   "network",
	Short: "Reset host network (restart required)",
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

	forceFlag, err := strconv.ParseBool(cmd.Flags().Lookup(forceFlagName).Value.String())
	if err != nil {
		return err
	}

	outputFlag, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return err
	}

	if err := context.Providers().System.ResetNetwork(provider.SystemResetNetworkConfig{
		Force:      forceFlag,
		ShowOutput: outputFlag,
	}); err != nil {
		return err
	}

	cmdSession.Finish()

	return nil
}
