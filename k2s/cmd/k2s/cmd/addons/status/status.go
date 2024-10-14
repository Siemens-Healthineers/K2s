// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package status

import (
	"errors"
	"log/slog"

	"github.com/spf13/cobra"

	"fmt"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/internal/setupinfo"
	"github.com/siemens-healthineers/k2s/internal/terminal"

	"github.com/siemens-healthineers/k2s/internal/addons"
	"github.com/siemens-healthineers/k2s/internal/json"
)

type StatusPrinter interface {
	PrintStatus(addonName string, loadFunc func(addonName string) (*LoadedAddonStatus, error)) error
	PrintSystemError(addon string, systemError error, systemCmdFailureFunc func() *common.CmdFailure) error
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

	configDir := cmd.Context().Value(common.ContextKeyConfigDir).(string)
	config, err := setupinfo.LoadConfig(configDir)
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemInCorruptedState) {
			return printer.PrintSystemError(addon.Metadata.Name, setupinfo.ErrSystemInCorruptedState, common.CreateSystemInCorruptedStateCmdFailure)
		}
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return printer.PrintSystemError(addon.Metadata.Name, setupinfo.ErrSystemNotInstalled, common.CreateSystemNotInstalledCmdFailure)
		}

		return err
	}

	loadFunc := func(addonName string) (*LoadedAddonStatus, error) {
		slog.Info("Loading status", "addon", addonName, "directory", addon.Directory)

		return LoadAddonStatus(addonName, addon.Directory, common.DeterminePsVersion(config))
	}

	return printer.PrintStatus(addon.Metadata.Name, loadFunc)
}

func determinePrinter(outputOption string) StatusPrinter {
	terminalPrinter := terminal.NewTerminalPrinter()

	if outputOption == jsonOption {
		return NewJsonPrinter(terminalPrinter, json.MarshalIndent)
	}
	return NewUserFriendlyPrinter(terminalPrinter)
}
