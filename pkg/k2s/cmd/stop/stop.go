// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package stop

import (
	"errors"
	"strconv"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
	"k8s.io/klog/v2"

	"k2s/cmd/common"
	p "k2s/cmd/params"
	c "k2s/config"
	cd "k2s/config/defs"
	"k2s/utils"
)

var Stopk8sCmd = &cobra.Command{
	Use:   "stop",
	Short: "Stops k2s cluster on the host machine",
	RunE:  stopk8s,
}

func init() {
	Stopk8sCmd.Flags().String(p.AdditionalHooksDirFlagName, "", p.AdditionalHooksDirFlagUsage)
	Stopk8sCmd.Flags().SortFlags = false
	Stopk8sCmd.Flags().PrintDefaults()
}

func stopk8s(ccmd *cobra.Command, args []string) error {
	pterm.Printfln("🛑 Stopping k2s cluster")

	stopCmd, err := buildStopCmd(ccmd)
	if err != nil {
		return err
	}

	klog.V(3).Infof("Stop command : %s", stopCmd)

	duration, err := utils.ExecutePowershellScript(stopCmd)
	if err != nil {
		return err
	}

	common.PrintCompletedMessage(duration, "Stop")

	return nil
}

func buildStopCmd(ccmd *cobra.Command) (string, error) {
	outputFlag, err := strconv.ParseBool(ccmd.Flags().Lookup(p.OutputFlagName).Value.String())
	if err != nil {
		return "", err
	}

	additionalHooksdir := ccmd.Flags().Lookup(p.AdditionalHooksDirFlagName).Value.String()

	config := c.NewAccess()

	installedSetupType, err := config.GetSetupType()
	if err != nil {
		return "", err
	}

	var cmd string

	switch installedSetupType {
	case cd.SetupTypek2s:
		cmd = utils.FormatScriptFilePath(c.SmallSetupDir() + "\\" + "StopK8s.ps1")
		if additionalHooksdir != "" {
			cmd += " -AdditionalHooksDir " + utils.EscapeWithSingleQuotes(additionalHooksdir)
		}
	case cd.SetupTypeMultiVMK8s:
		cmd = utils.FormatScriptFilePath(c.SetupRootDir + "\\smallsetup\\multivm\\" + "Stop_MultiVMK8sSetup.ps1")
		if additionalHooksdir != "" {
			cmd += " -AdditionalHooksDir " + utils.EscapeWithSingleQuotes(additionalHooksdir)
		}
	case cd.SetupTypeBuildOnlyEnv:
		return "", errors.New("there is no cluster to stop in build-only setup mode ;-). Aborting")
	default:
		return "", errors.New("could not determine the setup type, aborting. If you are sure you have a k2s setup installed, call the correct stop script directly")
	}

	if outputFlag {
		cmd += " -ShowLogs"
	}

	return cmd, nil
}
