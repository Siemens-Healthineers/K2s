// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package reset

import (
	"github.com/spf13/cobra"
	"k8s.io/klog/v2"

	"k2s/cmd/common"
	c "k2s/config"
	"k2s/providers/terminal"
	"k2s/utils"
)

var resetNetworkCmd = &cobra.Command{
	Use:   "network",
	Short: "Reset network (restart required)",
	RunE:  resetNetwork,
}

func init() {
	resetNetworkCmd.Flags().SortFlags = false
	resetNetworkCmd.Flags().PrintDefaults()
}

func resetNetwork(cmd *cobra.Command, args []string) error {
	config := c.NewAccess()

	installationType, err := config.GetSetupType()
	if err == nil && installationType != "" {
		terminal.NewTerminalPrinter().PrintInfofln("'%s' setup type is installed, please uninstall with 'k2s uninstall' first or reset system with 'k2s reset sytem' and re-run the 'k2s reset network' command afterwards.", installationType)
		return nil
	}

	resetNetworkCommand := utils.FormatScriptFilePath(utils.GetInstallationDirectory() + "\\smallsetup\\helpers\\ResetNetwork.ps1")
	klog.V(3).Infof("Reset network command: %s", resetNetworkCommand)

	duration, err := utils.ExecutePowershellScript(resetNetworkCommand)
	if err != nil {
		return err
	}

	common.PrintCompletedMessage(duration, "Network reset")

	return nil
}
