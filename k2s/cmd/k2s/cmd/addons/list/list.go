// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package list

import (
	"errors"
	"fmt"
	"log/slog"
	"path/filepath"

	"github.com/spf13/cobra"

	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"
	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/siemens-healthineers/k2s/internal/terminal"

	cc "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/list/print"
	"github.com/siemens-healthineers/k2s/internal/core/addons"
)

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

	context := cmd.Context().Value(cc.ContextKeyCmdContext).(*cc.CmdContext)
	config, err := setupinfo.ReadConfig(context.Config().Host.K2sConfigDir)
	psVersion := powershell.DefaultPsVersions
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemInCorruptedState) {
			return cc.CreateSystemInCorruptedStateCmdFailure()
		}
		if !errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return err
		}
		slog.Info("Setup not installed, falling back to default PowerShell version", "error", err, "version", psVersion)
	} else {
		psVersion = cc.DeterminePsVersion(config)
	}

	if outputOption == jsonOption {
		return printAddonsAsJson(allAddons, psVersion)
	}

	return printAddonsUserFriendly(allAddons, psVersion)
}

func printAddonsAsJson(allAddons addons.Addons, psVersion powershell.PowerShellVersion) error {
	terminalPrinter := terminal.NewTerminalPrinter()
	addonsPrinter := print.NewAddonsPrinter(terminalPrinter)

	enabledAddons, err := loadEnabledAddons(psVersion)
	if err != nil {
		return err
	}

	if err := addonsPrinter.PrintAddonsAsJson(enabledAddons, allAddons); err != nil {
		return fmt.Errorf("addons could not be printed: %w", err)
	}

	return nil
}

func printAddonsUserFriendly(allAddons addons.Addons, psVersion powershell.PowerShellVersion) error {
	terminalPrinter := terminal.NewTerminalPrinter()
	addonsPrinter := print.NewAddonsPrinter(terminalPrinter)

	spinner, err := cc.StartSpinner(terminalPrinter)
	if err != nil {
		return err
	}

	enabledAddons, err := loadEnabledAddons(psVersion)

	cc.StopSpinner(spinner)

	if err != nil {
		return err
	}

	terminalPrinter.PrintHeader("Available Addons")

	if err := addonsPrinter.PrintAddonsUserFriendly(enabledAddons, allAddons); err != nil {
		return fmt.Errorf("addons could not be printed: %w", err)
	}

	slog.Info("Addons listed")

	return nil
}

func loadEnabledAddons(psVersion powershell.PowerShellVersion) ([]print.EnabledAddon, error) {
	scriptPath := filepath.Join(utils.InstallDir(), addons.AddonsDirName, "Get-EnabledAddons.ps1")
	formattedPath := utils.FormatScriptFilePath(scriptPath)

	enabledAddons, err := powershell.ExecutePsWithStructuredResult[[]print.EnabledAddon](formattedPath, "EnabledAddons", psVersion, cc.NewPtermWriter())
	if err != nil {
		return nil, fmt.Errorf("could not load enabled addons: %s", err)
	}

	return enabledAddons, nil
}
