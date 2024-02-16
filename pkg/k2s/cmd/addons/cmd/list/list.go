// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package list

import (
	"errors"
	"fmt"

	cobra "github.com/spf13/cobra"
	"k8s.io/klog/v2"

	"k2s/addons"
	"k2s/addons/print"
	"k2s/providers/terminal"
)

type Spinner interface {
	Stop() error
}

const (
	Enabled        = "Enabled"
	Disabled       = "Disabled"
	outputFlagName = "output"
	jsonOption     = "json"
)

func NewCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "ls",
		Short: "List addons available for K2s",
		RunE:  listAddons,
	}

	cmd.Flags().StringP(outputFlagName, "o", "", "Output format modifier. Currently supported: 'json' for output as JSON structure")
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd
}

func listAddons(cmd *cobra.Command, args []string) error {
	klog.V(3).Info("Listing addons..")
	outputOption, err := cmd.Flags().GetString(outputFlagName)
	if err != nil {
		return err
	}

	if outputOption != "" && outputOption != jsonOption {
		return fmt.Errorf("parameter '%s' not supported for flag 'o'", outputOption)
	}

	if outputOption == jsonOption {
		return printAddonsAsJson()
	}

	return printAddonsUserFriendly()
}

func printAddonsAsJson() error {
	terminalPrinter := terminal.NewTerminalPrinter()
	addonsPrinter := print.NewAddonsPrinter(terminalPrinter)

	enabledAddons, err := addons.LoadEnabledAddons()
	if err != nil {
		return err
	}

	if err := addonsPrinter.PrintAddonsAsJson(enabledAddons.Addons, addons.AllAddons().ToPrintInfo()); err != nil {
		return fmt.Errorf("addons could not be printed: %w", err)
	}

	return nil
}

func printAddonsUserFriendly() error {
	terminalPrinter := terminal.NewTerminalPrinter()
	addonsPrinter := print.NewAddonsPrinter(terminalPrinter)

	spinner, err := startSpinner(terminalPrinter)
	if err != nil {
		return err
	}

	defer func() {
		err = spinner.Stop()
		if err != nil {
			klog.Error(err)
		}
	}()

	enabledAddons, err := addons.LoadEnabledAddons()
	if err != nil {
		return err
	}

	terminalPrinter.PrintHeader("Available Addons")

	if err := addonsPrinter.PrintAddons(enabledAddons.Addons, addons.AllAddons().ToPrintInfo()); err != nil {
		return fmt.Errorf("addons could not be printed: %w", err)
	}

	klog.V(3).Info("All addons listed")

	return nil
}

func startSpinner(terminalPrinter terminal.TerminalPrinter) (Spinner, error) {
	startResult, err := terminalPrinter.StartSpinner("Gathering addons information...")
	if err != nil {
		return nil, err
	}

	spinner, ok := startResult.(Spinner)
	if !ok {
		return nil, errors.New("could not start operation")
	}

	return spinner, nil
}
