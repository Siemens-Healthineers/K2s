// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package list

import (
	"errors"
	"fmt"
	"log/slog"

	"github.com/spf13/cobra"

	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/siemens-healthineers/k2s/internal/setupinfo"
	"github.com/siemens-healthineers/k2s/internal/terminal"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/common"
	cc "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/addons"

	"github.com/siemens-healthineers/k2s/cmd/k2s/addons/print"
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
			return listAddons(cmd, allAddons)
		},
	}

	cmd.Flags().StringP(outputFlagName, "o", "", "Output format modifier. Currently supported: 'json' for output as JSON structure")
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd
}

func listAddons(cmd *cobra.Command, allAddons addons.Addons) error {
	common.LogAddons(allAddons)

	slog.Info("Listing addons")

	outputOption, err := cmd.Flags().GetString(outputFlagName)
	if err != nil {
		return err
	}

	if outputOption != "" && outputOption != jsonOption {
		return fmt.Errorf("parameter '%s' not supported for flag 'o'", outputOption)
	}

	configDir := cmd.Context().Value(cc.ContextKeyConfigDir).(string)
	config, err := setupinfo.LoadConfig(configDir)
	psVersion := powershell.DefaultPsVersions
	if err != nil {
		if !errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return err
		}
		slog.Info("Setup not installed, falling back to default PowerShell version", "error", err, "version", psVersion)
	} else {
		psVersion = powershell.DeterminePsVersion(config)
	}

	if outputOption == jsonOption {
		return printAddonsAsJson(allAddons, psVersion)
	}

	return printAddonsUserFriendly(allAddons, psVersion)
}

func printAddonsAsJson(loadedAddons addons.Addons, psVersion powershell.PowerShellVersion) error {
	terminalPrinter := terminal.NewTerminalPrinter()
	addonsPrinter := print.NewAddonsPrinter(terminalPrinter)

	enabledAddons, err := addons.LoadEnabledAddons(psVersion)
	if err != nil {
		return err
	}

	if err := addonsPrinter.PrintAddonsAsJson(enabledAddons.Addons, loadedAddons.ToPrintInfo()); err != nil {
		return fmt.Errorf("addons could not be printed: %w", err)
	}

	return nil
}

func printAddonsUserFriendly(loadedAddons addons.Addons, psVersion powershell.PowerShellVersion) error {
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

	enabledAddons, err := addons.LoadEnabledAddons(psVersion)
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
