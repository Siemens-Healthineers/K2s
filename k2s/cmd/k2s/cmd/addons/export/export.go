// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package export

import (
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"time"

	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/siemens-healthineers/k2s/internal/terminal"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/siemens-healthineers/k2s/internal/setupinfo"

	ac "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/common"
	"github.com/siemens-healthineers/k2s/internal/addons"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	cobra "github.com/spf13/cobra"
)

var exportCommandExample = `
  # Export addon 'registry' and 'traefik' to specified folder
  k2s addons export registry traefik -d C:\tmp

  # Export all addons to specified folder
  k2s addons export -d C:\tmp
`

const (
	directoryLabel   = "directory"
	defaultDirectory = ""
	proxyLabel       = "proxy"
	defaultproxy     = ""
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
	cmd.Flags().StringP(proxyLabel, "p", defaultproxy, "HTTP Proxy")
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd
}

func runExport(cmd *cobra.Command, args []string) error {
	terminalPrinter := terminal.NewTerminalPrinter()
	allAddons, err := addons.LoadAddons(utils.InstallDir())
	if err != nil {
		return err
	}

	ac.LogAddons(allAddons)

	if err := ac.ValidateAddonNames(allAddons, "export", terminalPrinter, args...); err != nil {
		return err
	}

	psCmd, params, err := buildPsCmd(cmd, args...)
	if err != nil {
		return err
	}

	slog.Debug("PS command created", "command", psCmd, "params", params)

	start := time.Now()

	configDir := cmd.Context().Value(common.ContextKeyConfigDir).(string)
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

	if config.SetupName == setupinfo.SetupNameMultiVMK8s {
		return common.CreateFunctionalityNotAvailableCmdFailure(config.SetupName)
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
	common.PrintCompletedMessage(duration, "addons export")

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

	httpProxy, err := cmd.Flags().GetString(proxyLabel)
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag: %s", proxyLabel)
	}

	if httpProxy != "" {
		params = append(params, " -Proxy "+httpProxy)
	}

	return
}
