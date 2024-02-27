// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package reset

import (
	"strconv"
	"time"

	c "k2s/config"
	"k2s/utils/psexecutor"

	"github.com/spf13/cobra"

	"k2s/cmd/common"
	p "k2s/cmd/params"
	"k2s/providers/terminal"

	"k2s/utils"
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
	config := c.NewAccess()

	setupName, err := config.GetSetupName()
	if err == nil && setupName != "" {
		terminal.NewTerminalPrinter().PrintInfofln("'%s' setup is installed, please uninstall with 'k2s uninstall' first or reset system with 'k2s system reset' and re-run the 'k2s system reset network' command afterwards.", setupName)
		return nil
	}

	resetNetworkCommand := utils.FormatScriptFilePath(utils.GetInstallationDirectory() + "\\smallsetup\\helpers\\ResetNetwork.ps1")

	params := []string{}

	forceFlag, err := strconv.ParseBool(cmd.Flags().Lookup(forceFlagName).Value.String())
	if err != nil {
		return err
	}

	if forceFlag {
		params = append(params, " -Force")
	}

	outputFlag, err := strconv.ParseBool(cmd.Flags().Lookup(p.OutputFlagName).Value.String())
	if err != nil {
		return err
	}

	if outputFlag {
		params = append(params, " -ShowLogs")
	}

	start := time.Now()

	cmdResult, err := psexecutor.ExecutePsWithStructuredResult[*common.CmdResult](resetNetworkCommand, "CmdResult", psexecutor.ExecOptions{}, params...)

	duration := time.Since(start)

	if err != nil {
		return err
	}

	if cmdResult.Error != nil {
		return cmdResult.Error.ToError()
	}

	common.PrintCompletedMessage(duration, "system reset network")

	return nil
}
