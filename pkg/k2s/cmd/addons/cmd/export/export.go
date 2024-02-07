// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package export

import (
	"errors"
	"fmt"
	"k2s/addons"
	"k2s/providers/terminal"
	"k2s/utils"
	"strconv"
	"time"

	ac "k2s/cmd/addons/cmd/common"
	"k2s/cmd/common"
	p "k2s/cmd/params"

	cobra "github.com/spf13/cobra"
	"k8s.io/klog/v2"
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
	allAddons := addons.AllAddons()

	if !ac.ValidateAddonNames(allAddons, "export", terminalPrinter, args...) {
		return nil
	}

	psCmd, params, err := buildPsCmd(cmd, args...)
	if err != nil {
		return err
	}

	klog.V(4).Infof("PS cmd: '%s', params: '%v'", psCmd, params)

	start := time.Now()

	cmdResult, err := utils.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "CmdResult", utils.ExecOptions{}, params...)
	if err != nil {
		return err
	}

	if cmdResult.Error != nil {
		if isErrLinuxOnly(*cmdResult.Error) {
			terminalPrinter.PrintInfoln("Cannot export addons in Linux-only setup")
			return nil
		}

		return cmdResult.Error.ToError()
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

	psCmd = utils.FormatScriptFilePath(utils.GetInstallationDirectory() + "\\addons\\Export.ps1")
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

	outputFlag, err := strconv.ParseBool(cmd.Flags().Lookup(p.OutputFlagName).Value.String())
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

func isErrLinuxOnly(error common.CmdError) bool {
	return error == errLinuxOnlyMsg
}
