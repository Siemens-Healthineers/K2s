// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package status

import (
	"github.com/spf13/cobra"

	"fmt"

	"github.com/siemens-healthineers/k2s/cmd/k2s/addons/status"

	"github.com/siemens-healthineers/k2s/internal/terminal"

	"github.com/siemens-healthineers/k2s/cmd/k2s/addons"

	"github.com/siemens-healthineers/k2s/internal/json"
)

type StatusPrinter interface {
	PrintStatus(addonName string, addonDirectory string) error
}

type statusLoader struct {
}

const (
	outputFlagName = "output"
	jsonOption     = "json"
)

func NewCommand(allAddons addons.Addons) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "status",
		Short: "Prints the status of a specific addon",
	}

	for _, addon := range allAddons {
		cmd.AddCommand(newStatusCmd(addon))
	}

	return cmd
}

func (*statusLoader) LoadAddonStatus(addonName string, addonDirectory string) (*status.LoadedAddonStatus, error) {
	return status.LoadAddonStatus(addonName, addonDirectory)
}

func newStatusCmd(addon addons.Addon) *cobra.Command {
	statusCmd := &cobra.Command{
		Use:     addon.Metadata.Name,
		Short:   fmt.Sprintf("Prints the %s status", addon.Metadata.Name),
		Example: fmt.Sprintf("\n# Prints the %s status\nK2s addons status %s\n", addon.Metadata.Name, addon.Metadata.Name),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runStatusCmd(cmd, addon, determinePrinter)
		},
	}

	statusCmd.Flags().StringP(outputFlagName, "o", "", "Output format modifier. Currently supported: 'json' for output as JSON structure")
	statusCmd.Flags().SortFlags = false
	statusCmd.Flags().PrintDefaults()

	return statusCmd
}

func runStatusCmd(cmd *cobra.Command, addon addons.Addon, determinePrinterFunc func(outputOption string) StatusPrinter) error {
	outputOption, err := cmd.Flags().GetString(outputFlagName)
	if err != nil {
		return err
	}

	if outputOption != "" && outputOption != jsonOption {
		return fmt.Errorf("parameter '%s' not supported for flag '%s'", outputOption, outputFlagName)
	}

	printer := determinePrinterFunc(outputOption)

	return printer.PrintStatus(addon.Metadata.Name, addon.Directory)
}

func determinePrinter(outputOption string) StatusPrinter {
	terminalPrinter := terminal.NewTerminalPrinter()
	statusLoader := &statusLoader{}

	if outputOption == jsonOption {
		return status.NewJsonPrinter(terminalPrinter, statusLoader, json.MarshalIndent)
	} else {
		return status.NewUserFriendlyPrinter(terminalPrinter, statusLoader)
	}
}
