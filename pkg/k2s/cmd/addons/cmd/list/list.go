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
	Enabled  = "Enabled"
	Disabled = "Disabled"
)

func NewCommand(allAddons addons.Addons) *cobra.Command {
	return &cobra.Command{
		Use:   "ls",
		Short: "List addons available for K2s",
		RunE:  func(cmd *cobra.Command, args []string) error { return listAddons(allAddons) },
	}
}

func listAddons(allAddons addons.Addons) error {
	klog.V(3).Info("Listing addons..")

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
