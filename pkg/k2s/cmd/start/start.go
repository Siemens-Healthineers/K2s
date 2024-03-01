// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package start

import (
	"errors"
	"strconv"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
	"k8s.io/klog/v2"

	"k2s/cmd/common"
	p "k2s/cmd/params"
	c "k2s/config"
	"k2s/setupinfo"
	"k2s/utils"
	"k2s/utils/psexecutor"
	"k2s/utils/tz"
)

var Startk8sCmd = &cobra.Command{
	Use:   "start",
	Short: "Starts K2s cluster on the host machine",
	RunE:  startk8s,
}

func init() {
	Startk8sCmd.Flags().String(p.AdditionalHooksDirFlagName, "", p.AdditionalHooksDirFlagUsage)
	Startk8sCmd.Flags().BoolP(p.AutouseCachedVSwitchFlagName, "", false, p.AutouseCachedVSwitchFlagUsage)
	Startk8sCmd.Flags().SortFlags = false
	Startk8sCmd.Flags().PrintDefaults()
}

func startk8s(ccmd *cobra.Command, args []string) error {
	pterm.Printfln("🤖 Starting K2s on %s", utils.Platform())

	startCmd, err := buildStartCmd(ccmd)
	if err != nil {
		return err
	}

	tzConfigHandle, err := createTimezoneConfigHandle()
	if err != nil {
		return err
	}
	defer tzConfigHandle.Release()

	klog.V(3).Infof("Start command : %s", startCmd)

	duration, err := psexecutor.ExecutePowershellScript(startCmd)
	if err != nil {
		return err
	}

	common.PrintCompletedMessage(duration, "Start")

	return nil
}

func buildStartCmd(ccmd *cobra.Command) (string, error) {
	outputFlag, err := strconv.ParseBool(ccmd.Flags().Lookup(p.OutputFlagName).Value.String())
	if err != nil {
		return "", err
	}

	additionalHooksDir := ccmd.Flags().Lookup(p.AdditionalHooksDirFlagName).Value.String()

	autouseCachedVSwitch, err := strconv.ParseBool(ccmd.Flags().Lookup(p.AutouseCachedVSwitchFlagName).Value.String())
	if err != nil {
		return "", err
	}

	config := c.NewAccess()

	setupName, err := config.GetSetupName()
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return "", common.CreateSystemNotInstalledCmdFailure()
		}
		return "", err
	}

	var cmd string

	switch setupName {
	case setupinfo.SetupNamek2s:
		cmd = buildk2sStartCmd(outputFlag, additionalHooksDir, autouseCachedVSwitch)
	case setupinfo.SetupNameMultiVMK8s:
		cmd = buildMultiVMStartCmd(outputFlag, additionalHooksDir)
	case setupinfo.SetupNameBuildOnlyEnv:
		return "", errors.New("there is no cluster to start in build-only setup mode ;-). Aborting")
	default:
		return "", errors.New("could not determine the setup type, aborting. If you are sure you have a K2s setup installed, call the correct start script directly")
	}

	return cmd, nil
}

func buildk2sStartCmd(showLogs bool, additionalHooksDir string, autouseCachedVSwitch bool) string {
	cmd := utils.FormatScriptFilePath(c.SmallSetupDir() + "\\" + "StartK8s.ps1")

	if showLogs {
		cmd += " -ShowLogs"
	}

	if additionalHooksDir != "" {
		cmd += " -AdditionalHooksDir " + utils.EscapeWithSingleQuotes(additionalHooksDir)
	}

	if autouseCachedVSwitch {
		cmd += " -UseCachedK2sVSwitches"
	}

	return cmd
}

func buildMultiVMStartCmd(showLogs bool, additionalHooksDir string) string {
	cmd := utils.FormatScriptFilePath(c.SetupRootDir + "\\smallsetup\\multivm\\" + "Start_MultiVMK8sSetup.ps1")

	if showLogs {
		cmd += " -ShowLogs"
	}

	if additionalHooksDir != "" {
		cmd += " -AdditionalHooksDir " + utils.EscapeWithSingleQuotes(additionalHooksDir)
	}

	return cmd
}

func createTimezoneConfigHandle() (tz.ConfigWorkspaceHandle, error) {
	tzConfigWorkspace, err := tz.NewTimezoneConfigWorkspace()
	if err != nil {
		return nil, err
	}
	tzConfigHandle, err := tzConfigWorkspace.CreateHandle()
	if err != nil {
		return nil, err
	}
	return tzConfigHandle, nil
}
