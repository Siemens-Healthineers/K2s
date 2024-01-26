// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package export

import (
	"errors"
	"fmt"
	"k2s/addons"
	"k2s/setupinfo"
	"k2s/utils"
	"strconv"

	"k2s/cmd/common"
	p "k2s/cmd/params"
	"k2s/providers/terminal"

	"github.com/samber/lo"
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
)

func NewCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:     "export ADDON",
		Short:   "Export addon",
		Example: exportCommandExample,
		RunE:    exportAddons,
	}

	cmd.Flags().StringP(directoryLabel, "d", defaultDirectory, "Directory for addon export")
	cmd.Flags().StringP(proxyLabel, "p", defaultproxy, "HTTP Proxy")
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd
}

func exportAddons(cmd *cobra.Command, args []string) error {
	if len(args) == 0 {
		exportCmd, err := buildExportCmdForAllAddons(cmd)
		if err != nil {
			return err
		}

		klog.V(3).Infof("export command : %s", exportCmd)

		duration, err := utils.ExecutePowershellScript(exportCmd)
		if err != nil {
			return err
		}

		common.PrintCompletedMessage(duration, "addons export")
		return nil
	}

	allAddons := addons.AllAddons()

	addonFound := true
	for _, addonName := range args {
		found := lo.ContainsBy(allAddons, func(addon addons.Addon) bool {
			return addon.Metadata.Name == addonName
		})

		if !found {
			addonFound = false
			break
		}
	}

	if addonFound {
		exportCommand, err := buildExportCmdForSpecificAddons(cmd, args)
		if err != nil {
			return err
		}

		klog.V(3).Infof("export command : %s", exportCommand)

		duration, err := utils.ExecutePowershellScript(exportCommand)
		switch err {
		case nil:
			break
		case setupinfo.ErrNotInstalled:
			common.PrintNotInstalledMessage()
			return nil
		default:
			return err
		}

		common.PrintCompletedMessage(duration, "addons export")
	} else {
		terminalPrinter := terminal.NewTerminalPrinter()
		printAvailableAddons(allAddons, terminalPrinter)
	}

	return nil
}

func buildExportCmdForSpecificAddons(ccmd *cobra.Command, addonsToExport []string) (string, error) {
	exportPath, err := ccmd.Flags().GetString(directoryLabel)
	if err != nil {
		return "", fmt.Errorf("unable to parse flag: %s", directoryLabel)
	}
	if exportPath == "" {
		return "", errors.New("no export path provided")
	}

	names := ""
	for _, addon := range addonsToExport {
		names += utils.EscapeWithSingleQuotes(addon) + ","
	}
	names = names[:len(names)-1]

	exportCommand := utils.FormatScriptFilePath(utils.GetInstallationDirectory()+"\\addons\\Export.ps1") + " -ExportDir " + utils.EscapeWithSingleQuotes(exportPath) + " -Names " + names

	outputFlag, err := strconv.ParseBool(ccmd.Flags().Lookup(p.OutputFlagName).Value.String())
	if err != nil {
		return "", err
	}

	if outputFlag {
		exportCommand += " -ShowLogs"
	}

	httpProxy, err := ccmd.Flags().GetString(proxyLabel)
	if err != nil {
		return "", fmt.Errorf("unable to parse flag: %s", proxyLabel)
	}

	if httpProxy != "" {
		exportCommand += " -Proxy " + httpProxy
	}

	return exportCommand, nil
}

func buildExportCmdForAllAddons(ccmd *cobra.Command) (string, error) {
	exportPath, err := ccmd.Flags().GetString(directoryLabel)
	if err != nil {
		return "", fmt.Errorf("unable to parse flag: %s", directoryLabel)
	}
	if exportPath == "" {
		return "", errors.New("no export path provided")
	}

	exportCommand := utils.FormatScriptFilePath(utils.GetInstallationDirectory()+"\\addons\\Export.ps1") + " -ExportDir " + utils.EscapeWithSingleQuotes(exportPath) + " -All"

	outputFlag, err := strconv.ParseBool(ccmd.Flags().Lookup(p.OutputFlagName).Value.String())
	if err != nil {
		return "", err
	}

	if outputFlag {
		exportCommand += " -ShowLogs"
	}

	httpProxy, err := ccmd.Flags().GetString(proxyLabel)
	if err != nil {
		return "", fmt.Errorf("unable to parse flag: %s", proxyLabel)
	}

	if httpProxy != "" {
		exportCommand += " -Proxy " + httpProxy
	}

	return exportCommand, nil
}

func printAvailableAddons(allAddons addons.Addons, terminalPrinter terminal.TerminalPrinter) {
	terminalPrinter.PrintHeader("Please check Addons spelling, not all specified Addons found!")
	terminalPrinter.Println()
	terminalPrinter.PrintHeader("Available Addons to export:")

	tableHeaders := []string{"NAME"}
	addonTable := [][]string{tableHeaders}

	for _, addon := range allAddons {
		row := []string{string(addon.Metadata.Name)}
		addonTable = append(addonTable, row)
	}

	terminalPrinter.PrintTableWithHeaders(addonTable)
}
