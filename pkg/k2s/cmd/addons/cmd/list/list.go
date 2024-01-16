// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package list

import (
	"errors"

	cobra "github.com/spf13/cobra"
	"k8s.io/klog/v2"

	"k2s/addons"
	"k2s/addons/print"
	"k2s/providers/terminal"
)

type Spinner interface {
	Stop() error
	Fail(m ...any)
}

const (
	Enabled  = "Enabled"
	Disabled = "Disabled"
)

func NewCommand(allAddons addons.Addons) *cobra.Command {
	return &cobra.Command{
		Use:   "ls",
		Short: "List addons available for k2s",
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

	enabledAddons, err := addons.LoadEnabledAddons()
	if err != nil {
		if err := spinner.Stop(); err != nil {
			klog.Error(err)
		}
		return err
	}

	terminalPrinter.PrintHeader("Available Addons")

	if err := addonsPrinter.PrintAddons(enabledAddons.Addons, addons.AllAddons().ToPrintInfo()); err != nil {
		spinner.Fail("addons could not be printed")
		return err
	}

	if err := spinner.Stop(); err != nil {
		return err
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
