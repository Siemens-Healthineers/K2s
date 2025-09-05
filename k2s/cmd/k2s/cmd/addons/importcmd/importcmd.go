// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package importcmd

import (
	"errors"
	"fmt"
	"log/slog"
	"strconv"

	"github.com/siemens-healthineers/k2s/internal/powershell"

	ac "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/common"
	cconfig "github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/core/addons"
	"github.com/siemens-healthineers/k2s/internal/core/config"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/spf13/cobra"
)

var importCommandExample = `
  # Import addon "registry" and "ingress nginx"  from an exported tar archive
  k2s addons import registry "ingress nginx" -z C:\tmp\addons.zip

  # Import all addons from an exported tar archive
  k2s addons import -z C:\tmp\addons.zip
`

const (
	zipLabel   = "zip"
	defaultZip = ""
)

func NewCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:     "import ADDON",
		Short:   "Import an addon from a zip file",
		Example: importCommandExample,
		RunE:    runImport,
	}

	cmd.Flags().StringP(zipLabel, "z", defaultZip, "zip archive of exported addon")
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd
}

func runImport(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	allAddons, err := addons.LoadAddons(utils.InstallDir())
	if err != nil {
		return err
	}

	ac.LogAddons(allAddons)

	psCmd, params, err := buildPsCmd(cmd, args...)
	if err != nil {
		return err
	}

	slog.Debug("PS command created", "command", psCmd, "params", params)

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	runtimeConfig, err := config.ReadRuntimeConfig(context.Config().Host().K2sSetupConfigDir())
	if err != nil {
		if errors.Is(err, cconfig.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		if errors.Is(err, cconfig.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	if runtimeConfig.InstallConfig().LinuxOnly() {
		return common.CreateFuncUnavailableForLinuxOnlyCmdFailure()
	}

	cmdResult, err := powershell.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "CmdResult", common.NewPtermWriter(), params...)
	if err != nil {
		return err
	}

	if cmdResult.Failure != nil {
		return cmdResult.Failure
	}

	cmdSession.Finish()

	return nil
}

func buildPsCmd(cmd *cobra.Command, addons ...string) (psCmd string, params []string, err error) {
	psCmd = utils.FormatScriptFilePath(utils.InstallDir() + "\\addons\\Import.ps1")

	if len(addons) > 0 {
		names := ""
		for _, addon := range addons {
			names += utils.EscapeWithSingleQuotes(addon) + ","
		}
		names = names[:len(names)-1]

		params = append(params, " -Names "+names)
	}

	imagePath, err := cmd.Flags().GetString(zipLabel)
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag: %s", zipLabel)
	}
	if imagePath == "" {
		return "", nil, errors.New("no path to tar archive provided")
	}

	params = append(params, " -Zipfile "+utils.EscapeWithSingleQuotes(imagePath))

	outputFlag, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return "", nil, err
	}

	if outputFlag {
		params = append(params, " -ShowLogs")
	}

	return
}
