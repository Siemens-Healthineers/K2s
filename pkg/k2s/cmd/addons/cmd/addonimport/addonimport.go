// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package addonimport

import (
	"errors"
	"fmt"
	"k2s/addons"
	ac "k2s/cmd/addons/cmd/common"
	"k2s/cmd/common"
	p "k2s/cmd/params"
	"k2s/providers/terminal"
	"k2s/utils"
	"k2s/utils/psexecutor"
	"strconv"
	"time"

	"github.com/spf13/cobra"
	"k8s.io/klog/v2"
)

var importCommandExample = `
  # Import addon 'ingress-nginx' and 'traefik' from an exported tar archive
  k2s addons import ingress-nginx traefik -z C:\tmp\addons.zip

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
	terminalPrinter := terminal.NewTerminalPrinter()
	allAddons := addons.AllAddons()

	if !ac.ValidateAddonNames(allAddons, "import", terminalPrinter, args...) {
		return nil
	}

	psCmd, params, err := buildPsCmd(cmd, args...)
	if err != nil {
		return err
	}

	klog.V(4).Infof("PS cmd: '%s', params: '%v'", psCmd, params)

	start := time.Now()

	cmdResult, err := psexecutor.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "CmdResult", psexecutor.ExecOptions{}, params...)

	duration := time.Since(start)

	if err != nil {
		return err
	}

	if cmdResult.Error != nil {
		return cmdResult.Error.ToError()
	}

	common.PrintCompletedMessage(duration, "addons import")

	return nil
}

func buildPsCmd(cmd *cobra.Command, addons ...string) (psCmd string, params []string, err error) {
	psCmd = utils.FormatScriptFilePath(utils.GetInstallationDirectory() + "\\addons\\Import.ps1")

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

	outputFlag, err := strconv.ParseBool(cmd.Flags().Lookup(p.OutputFlagName).Value.String())
	if err != nil {
		return "", nil, err
	}

	if outputFlag {
		params = append(params, " -ShowLogs")
	}

	return
}
