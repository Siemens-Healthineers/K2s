// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package addonimport

import (
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"time"

	"github.com/siemens-healthineers/k2s/internal/providers/terminal"

	p "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/params"

	ac "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/common"

	acc "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/addons"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils/psexecutor"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/siemens-healthineers/k2s/cmd/k2s/setupinfo"

	"github.com/spf13/cobra"
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
	allAddons, err := addons.LoadAddons()
	if err != nil {
		return err
	}

	ac.LogAddons(allAddons)

	if err := acc.ValidateAddonNames(allAddons, "import", terminalPrinter, args...); err != nil {
		return err
	}

	psCmd, params, err := buildPsCmd(cmd, args...)
	if err != nil {
		return err
	}

	slog.Debug("PS command created", "command", psCmd, "params", params)

	start := time.Now()

	cmdResult, err := psexecutor.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "CmdResult", psexecutor.ExecOptions{}, params...)
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	if cmdResult.Failure != nil {
		return cmdResult.Failure
	}

	duration := time.Since(start)
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