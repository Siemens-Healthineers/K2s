// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package stop

import (
	"errors"
	"log/slog"
	"strconv"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"

	p "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/params"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils/psexecutor"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/siemens-healthineers/k2s/internal/setupinfo"
)

var Stopk8sCmd = &cobra.Command{
	Use:   "stop",
	Short: "Stops K2s cluster on the host machine",
	RunE:  stopk8s,
}

func init() {
	Stopk8sCmd.Flags().String(p.AdditionalHooksDirFlagName, "", p.AdditionalHooksDirFlagUsage)
	Stopk8sCmd.Flags().BoolP(p.CacheVSwitchFlagName, "", false, p.CacheVSwitchFlagUsage)
	Stopk8sCmd.Flags().SortFlags = false
	Stopk8sCmd.Flags().PrintDefaults()
}

func stopk8s(cmd *cobra.Command, args []string) error {
	pterm.Printfln("🛑 Stopping K2s cluster")

	configDir := cmd.Context().Value(common.ContextKeyConfigDir).(string)
	config, err := setupinfo.LoadConfig(configDir)
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	stopCmd, err := buildStopCmd(cmd.Flags(), config.SetupName)
	if err != nil {
		return err
	}

	slog.Debug("PS command created", "command", stopCmd)

	duration, err := psexecutor.ExecutePowershellScript(stopCmd, common.DeterminePsVersion(config))
	if err != nil {
		return err
	}

	common.PrintCompletedMessage(duration, "Stop")

	return nil
}

func buildStopCmd(flags *pflag.FlagSet, setupName setupinfo.SetupName) (string, error) {
	outputFlag, err := strconv.ParseBool(flags.Lookup(p.OutputFlagName).Value.String())
	if err != nil {
		return "", err
	}

	additionalHooksdir := flags.Lookup(p.AdditionalHooksDirFlagName).Value.String()

	cacheVSwitches, err := strconv.ParseBool(flags.Lookup(p.CacheVSwitchFlagName).Value.String())
	if err != nil {
		return "", err
	}

	var cmd string

	switch setupName {
	case setupinfo.SetupNamek2s:
		cmd = utils.FormatScriptFilePath(utils.InstallDir() + "\\smallsetup\\StopK8s.ps1")
		if additionalHooksdir != "" {
			cmd += " -AdditionalHooksDir " + utils.EscapeWithSingleQuotes(additionalHooksdir)
		}
		if cacheVSwitches {
			cmd += " -CacheK2sVSwitches"
		}
	case setupinfo.SetupNameMultiVMK8s:
		cmd = utils.FormatScriptFilePath(utils.InstallDir() + "\\smallsetup\\multivm\\Stop_MultiVMK8sSetup.ps1")
		if additionalHooksdir != "" {
			cmd += " -AdditionalHooksDir " + utils.EscapeWithSingleQuotes(additionalHooksdir)
		}
	case setupinfo.SetupNameBuildOnlyEnv:
		return "", errors.New("there is no cluster to stop in build-only setup mode ;-). Aborting")
	default:
		return "", errors.New("could not determine the setup type, aborting. If you are sure you have a K2s setup installed, call the correct stop script directly")
	}

	if outputFlag {
		cmd += " -ShowLogs"
	}

	return cmd, nil
}
