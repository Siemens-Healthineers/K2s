// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package list

import (
	"errors"
	"fmt"
	"log/slog"

	cobra "github.com/spf13/cobra"
	"github.com/spf13/pflag"

	"k2s/addons"
	"k2s/addons/print"
	"k2s/cmd/addons/common"
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

func NewCommand(allAddons addons.Addons) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "ls",
		Short: "List addons available for K2s",
		RunE: func(cmd *cobra.Command, args []string) error {
			return listAddons(cmd.Flags(), allAddons)
		},
	}

	cmd.Flags().StringP(outputFlagName, "o", "", "Output format modifier. Currently supported: 'json' for output as JSON structure")
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd
}

func listAddons(flagSet *pflag.FlagSet, allAddons addons.Addons) error {
	common.LogAddons(allAddons)

	slog.Info("Listing addons")

	outputOption, err := flagSet.GetString(outputFlagName)
	if err != nil {
		return err
	}

	if outputOption != "" && outputOption != jsonOption {
		return fmt.Errorf("parameter '%s' not supported for flag 'o'", outputOption)
	}

	if outputOption == jsonOption {
		return printAddonsAsJson(allAddons)
	}

	return printAddonsUserFriendly(allAddons)
}

func printAddonsAsJson(loadedAddons addons.Addons) error {
	terminalPrinter := terminal.NewTerminalPrinter()
	addonsPrinter := print.NewAddonsPrinter(terminalPrinter)

	enabledAddons, err := addons.LoadEnabledAddons()
	if err != nil {
		return err
	}

	if err := addonsPrinter.PrintAddonsAsJson(enabledAddons.Addons, loadedAddons.ToPrintInfo()); err != nil {
		return fmt.Errorf("addons could not be printed: %w", err)
	}

	return nil
}

func printAddonsUserFriendly(loadedAddons addons.Addons) error {
	terminalPrinter := terminal.NewTerminalPrinter()
	addonsPrinter := print.NewAddonsPrinter(terminalPrinter)

	spinner, err := startSpinner(terminalPrinter)
	if err != nil {
		return err
	}

	defer func() {
		err = spinner.Stop()
		if err != nil {
			slog.Error("spinner stop", "error", err)
		}
	}()

	enabledAddons, err := addons.LoadEnabledAddons()
	if err != nil {
		return err
	}

	terminalPrinter.PrintHeader("Available Addons")

	if err := addonsPrinter.PrintAddons(enabledAddons.Addons, loadedAddons.ToPrintInfo()); err != nil {
		return fmt.Errorf("addons could not be printed: %w", err)
	}

	slog.Info("Addons listed")

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
