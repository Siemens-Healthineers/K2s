// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package common

import (
	"fmt"

	"github.com/siemens-healthineers/k2s/internal/providers/terminal"

	"github.com/siemens-healthineers/k2s/cmd/k2s/addons"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/samber/lo"
)

func ValidateAddonNames(allAddons addons.Addons, activity string, terminalPrinter terminal.TerminalPrinter, names ...string) error {
	for _, name := range names {
		found := lo.ContainsBy(allAddons, func(addon addons.Addon) bool {
			return addon.Metadata.Name == name
		})

		if !found {
			printValidAddonNames(allAddons, terminalPrinter)

			return &common.CmdFailure{
				Severity: common.SeverityWarning,
				Code:     "addon-name-invalid",
				Message:  fmt.Sprintf("Addon '%s' not supported for %s, aborting.", name, activity),
			}
		}
	}

	return nil
}

func printValidAddonNames(allAddons addons.Addons, terminalPrinter terminal.TerminalPrinter) {
	tableHeaders := []string{"Available addon names"}
	addonTable := [][]string{tableHeaders}

	for _, addon := range allAddons {
		row := []string{string(addon.Metadata.Name)}
		addonTable = append(addonTable, row)
	}

	terminalPrinter.PrintTableWithHeaders(addonTable)
}
