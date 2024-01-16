// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package reset

import (
	"github.com/spf13/cobra"
	"k8s.io/klog/v2"

	"k2s/cmd/common"
	"k2s/utils"
)

var resetSystemCmd = &cobra.Command{
	Use:   "system",
	Short: "Resets system to origin state",
	RunE:  resetSystem,
}

func init() {
	resetSystemCmd.Flags().SortFlags = false
	resetSystemCmd.Flags().PrintDefaults()
}

func resetSystem(cmd *cobra.Command, args []string) error {
	resetSystemCommand, err := buildResetSystemCmd(cmd)
	if err != nil {
		return err
	}

	klog.V(3).Infof("Reset system command: %s", resetSystemCommand)

	duration, err := utils.ExecutePowershellScript(resetSystemCommand)
	if err != nil {
		return err
	}

	common.PrintCompletedMessage(duration, "System reset")

	return nil
}

func buildResetSystemCmd(cmd *cobra.Command) (string, error) {
	resetSystemCommand := utils.FormatScriptFilePath(utils.GetInstallationDirectory() + "\\smallsetup\\helpers\\ResetSystem.ps1")

	return resetSystemCommand, nil
}
