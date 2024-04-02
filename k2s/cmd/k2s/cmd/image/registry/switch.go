// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package registry

import (
	"errors"
	"log/slog"
	"strconv"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/siemens-healthineers/k2s/internal/setupinfo"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
)

var (
	switchExample = `
	# Login to configured registry 'myregistry' registry in K2s 
	k2s image registry switch myregistry
`

	switchCmd = &cobra.Command{
		Use:     "switch",
		Short:   "Switch to a configured registry",
		RunE:    switchRegistry,
		Example: switchExample,
	}
)

func init() {
	switchCmd.Flags().SortFlags = false
	switchCmd.Flags().PrintDefaults()
}

func switchRegistry(cmd *cobra.Command, args []string) error {
	if len(args) == 0 || args[0] == "" {
		return errors.New("no registry passed in CLI, use e.g. 'k2s image registry switch <registry-name>'")
	}

	registryName := args[0]

	slog.Info("Switching registry", "registry", registryName)

	pterm.Printfln("🤖 Switching to registry '%s'", registryName)

	psCmd, params, err := buildSwitchPsCmd(registryName, cmd)
	if err != nil {
		return err
	}

	slog.Debug("PS command created", "command", psCmd, "params", params)

	start := time.Now()

	configDir := cmd.Context().Value(common.ContextKeyConfigDir).(string)
	config, err := setupinfo.LoadConfig(configDir)
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	outputWriter, err := common.NewOutputWriter()
	if err != nil {
		return err
	}

	cmdResult, err := powershell.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "CmdResult", common.DeterminePsVersion(config), outputWriter, params...)
	if err != nil {
		return err
	}

	if cmdResult.Failure != nil {
		return cmdResult.Failure
	}

	duration := time.Since(start)

	common.PrintCompletedMessage(duration, "image registry switch")

	return nil
}

func buildSwitchPsCmd(registryName string, cmd *cobra.Command) (psCmd string, params []string, err error) {
	psCmd = utils.FormatScriptFilePath(utils.InstallDir() + "\\smallsetup\\helpers\\SwitchRegistry.ps1")

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return "", nil, err
	}

	if showOutput {
		params = append(params, " -ShowLogs")
	}

	params = append(params, " -RegistryName "+registryName)

	return
}
