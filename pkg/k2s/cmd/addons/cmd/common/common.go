// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package common

import (
	"errors"
	"k2s/addons"
	"k2s/providers/terminal"
	"k2s/setupinfo"
	"k2s/status"

	"github.com/pterm/pterm"
	"github.com/samber/lo"
)

type AddonCmdError string

type AddonCmdResult struct {
	Error *AddonCmdError `json:"error"`
}

func (err AddonCmdError) ToError() error {
	if status.IsErrNotRunning(string(err)) {
		return status.ErrNotRunning
	}
	if setupinfo.IsErrNotInstalled(string(err)) {
		return setupinfo.ErrNotInstalled
	}

	return errors.New(string(err))
}

func PrintAddonNotFoundMsg(dir string, name string) {
	pterm.Warning.Printfln("Addon '%s' not found in directory '%s'", name, dir)
}

func PrintNoAddonStatusMsg(name string) {
	pterm.Info.Printfln("Addon '%s' does not provide detailed status information", name)
}

func ValidateAddonNames(allAddons addons.Addons, activity string, terminalPrinter terminal.TerminalPrinter, names ...string) bool {
	for _, name := range names {
		found := lo.ContainsBy(allAddons, func(addon addons.Addon) bool {
			return addon.Metadata.Name == name
		})

		if !found {
			printAddonActivityNotSupportedMsg(name, allAddons, activity, terminalPrinter)
			return false
		}
	}

	return true
}

func printAddonActivityNotSupportedMsg(name string, allAddons addons.Addons, activity string, terminalPrinter terminal.TerminalPrinter) {
	terminalPrinter.PrintInfofln("Addon '%s' not supported for %s, aborting.", name, activity)
	terminalPrinter.Println()

	tableHeaders := []string{"Available addon names"}
	addonTable := [][]string{tableHeaders}

	for _, addon := range allAddons {
		row := []string{string(addon.Metadata.Name)}
		addonTable = append(addonTable, row)
	}

	terminalPrinter.PrintTableWithHeaders(addonTable)
}
