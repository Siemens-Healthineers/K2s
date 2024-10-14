// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package start

import (
	"errors"
	"log/slog"
	"strconv"
	"time"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils/tz"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/siemens-healthineers/k2s/internal/setupinfo"
)

var Startk8sCmd = &cobra.Command{
	Use:   "start",
	Short: "Starts K2s cluster on the host machine",
	RunE:  startk8s,
}

func init() {
	Startk8sCmd.Flags().String(common.AdditionalHooksDirFlagName, "", common.AdditionalHooksDirFlagUsage)
	Startk8sCmd.Flags().BoolP(common.AutouseCachedVSwitchFlagName, "", false, common.AutouseCachedVSwitchFlagUsage)
	Startk8sCmd.Flags().SortFlags = false
	Startk8sCmd.Flags().PrintDefaults()
}

func startk8s(ccmd *cobra.Command, args []string) error {
	pterm.Printfln("🤖 Starting K2s on %s", utils.Platform())

	configDir := ccmd.Context().Value(common.ContextKeyConfigDir).(string)
	config, err := setupinfo.LoadConfig(configDir)
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	startCmd, err := buildStartCmd(ccmd.Flags(), config.SetupName)
	if err != nil {
		return err
	}

	tzConfigHandle, err := createTimezoneConfigHandle()
	if err != nil {
		return err
	}
	defer tzConfigHandle.Release()

	slog.Debug("PS command created", "command", startCmd)

	outputWriter, err := common.NewOutputWriter()
	if err != nil {
		return err
	}

	start := time.Now()

	err = powershell.ExecutePs(startCmd, common.DeterminePsVersion(config), outputWriter)
	if err != nil {
		return err
	}

	duration := time.Since(start)
	common.PrintCompletedMessage(duration, "Start")

	return nil
}

func buildStartCmd(flags *pflag.FlagSet, setupName setupinfo.SetupName) (string, error) {
	outputFlag, err := strconv.ParseBool(flags.Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return "", err
	}

	additionalHooksDir := flags.Lookup(common.AdditionalHooksDirFlagName).Value.String()

	autouseCachedVSwitch, err := strconv.ParseBool(flags.Lookup(common.AutouseCachedVSwitchFlagName).Value.String())
	if err != nil {
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
	cmd := utils.FormatScriptFilePath(utils.InstallDir() + "\\smallsetup\\StartK8s.ps1")

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
	cmd := utils.FormatScriptFilePath(utils.InstallDir() + "\\smallsetup\\multivm\\Start_MultiVMK8sSetup.ps1")

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
