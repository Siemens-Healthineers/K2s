// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package status

import (
	"errors"
	"log/slog"
	"path/filepath"

	"github.com/spf13/cobra"

	"fmt"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/internal/terminal"

	cconfig "github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/core/addons"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/json"
)

type StatusPrinter interface {
	PrintStatus(addonName string, implementation string, loadFunc func(addonName string, implementation string) (*LoadedAddonStatus, error)) error
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
		Use:   addon.Metadata.Name,
		Short: fmt.Sprintf("Prints the %s status", addon.Metadata.Name),
	}

	for _, implementation := range addon.Spec.Implementations {
		if addon.Metadata.Name != implementation.Name {
			slog.Debug("Creating sub-command for addon implementation", "command", "status", "addon", addon.Metadata.Name, "implementation", implementation)
			implementationCmd := newImplementationCmd(addon, implementation)
			statusCmd.AddCommand(implementationCmd)
		} else {
			statusCmd.Example = fmt.Sprintf("\n# Prints the %s status\nK2s addons status %s\n", addon.Metadata.Name, addon.Metadata.Name)
			statusCmd.RunE = func(cmd *cobra.Command, args []string) error {
				return runStatusCmd(cmd, addon, "", determinePrinter)
			}
			statusCmd.Flags().StringP(outputFlagName, "o", "", "Output format modifier. Currently supported: 'json' for output as JSON structure")
			statusCmd.Flags().SortFlags = false
			statusCmd.Flags().PrintDefaults()
		}
	}

	return statusCmd
}

func newImplementationCmd(addon addons.Addon, implementation addons.Implementation) *cobra.Command {
	cmd := &cobra.Command{
		Use:   implementation.Name,
		Short: fmt.Sprintf("Prints the %s %s status", addon.Metadata.Name, implementation.Name),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runStatusCmd(cmd, addon, implementation.Name, determinePrinter)
		},
	}

	cmd.Flags().StringP(outputFlagName, "o", "", "Output format modifier. Currently supported: 'json' for output as JSON structure")
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd
}

func runStatusCmd(cmd *cobra.Command, addon addons.Addon, implementation string, determinePrinterFunc func(outputOption string) StatusPrinter) error {
	outputOption, err := cmd.Flags().GetString(outputFlagName)
	if err != nil {
		return err
	}

	if outputOption != "" && outputOption != jsonOption {
		return fmt.Errorf("parameter '%s' not supported for flag '%s'", outputOption, outputFlagName)
	}

	printer := determinePrinterFunc(outputOption)

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	runtimeConfig, err := config.ReadRuntimeConfig(context.Config().Host().K2sSetupConfigDir())
	if err != nil {
		if errors.Is(err, cconfig.ErrSystemInCorruptedState) {
			return printer.PrintSystemError(addon.Metadata.Name, cconfig.ErrSystemInCorruptedState, common.CreateSystemInCorruptedStateCmdFailure)
		}
		if errors.Is(err, cconfig.ErrSystemNotInstalled) {
			return printer.PrintSystemError(addon.Metadata.Name, cconfig.ErrSystemNotInstalled, common.CreateSystemNotInstalledCmdFailure)
		}

		return err
	}

	if err := context.EnsureK2sK8sContext(runtimeConfig.ClusterConfig().Name()); err != nil {
		return err
	}

	loadFunc := func(addonName string, implementation string) (*LoadedAddonStatus, error) {
		slog.Info("Loading status", "addon", addonName, "directory", addon.Directory)

		if implementation != "" {
			return LoadAddonStatus(addonName, filepath.Join(addon.Directory, implementation))
		}

		return LoadAddonStatus(addonName, addon.Directory)
	}

	return printer.PrintStatus(addon.Metadata.Name, implementation, loadFunc)
}

func determinePrinter(outputOption string) StatusPrinter {
	terminalPrinter := terminal.NewTerminalPrinter()

	if outputOption == jsonOption {
		return NewJsonPrinter(terminalPrinter, json.MarshalIndent)
	}
	return NewUserFriendlyPrinter(terminalPrinter)
}
