// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package export

import (
	"errors"
	"fmt"
	"log/slog"
	"strconv"

	"github.com/siemens-healthineers/k2s/internal/powershell"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	ac "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/common"
	cconfig "github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/core/addons"
	"github.com/siemens-healthineers/k2s/internal/core/config"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	cobra "github.com/spf13/cobra"
)

var exportCommandExample = `
  # Export addon "registry" and "ingress nginx" to specified folder
  k2s addons export registry "ingress nginx" -d C:\tmp

  # Export all addons to specified folder
  k2s addons export -d C:\tmp
`

const (
	directoryLabel   = "directory"
	defaultDirectory = ""
	errLinuxOnlyMsg  = "linux-only"
)

func NewCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:     "export ADDON",
		Short:   "Export addon",
		Example: exportCommandExample,
		RunE:    runExport,
	}

	cmd.Flags().StringP(directoryLabel, "d", defaultDirectory, "Directory for addon export")
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd
}

func runExport(cmd *cobra.Command, args []string) error {
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

func buildPsCmd(cmd *cobra.Command, addonsToExport ...string) (psCmd string, params []string, err error) {
	exportPath, err := cmd.Flags().GetString(directoryLabel)
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag: %s", directoryLabel)
	}
	if exportPath == "" {
		return "", nil, errors.New("no export path provided")
	}

	psCmd = utils.FormatScriptFilePath(utils.InstallDir() + "\\addons\\Export.ps1")
	params = append(params, " -ExportDir "+utils.EscapeWithSingleQuotes(exportPath))

	if len(addonsToExport) > 0 {
		names := ""
		for _, addon := range addonsToExport {
			names += utils.EscapeWithSingleQuotes(addon) + ","
		}
		names = names[:len(names)-1]

		params = append(params, " -Names "+names)
	} else {
		params = append(params, " -All")
	}

	outputFlag, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return "", nil, err
	}

	if outputFlag {
		params = append(params, " -ShowLogs")
	}

	return
}
