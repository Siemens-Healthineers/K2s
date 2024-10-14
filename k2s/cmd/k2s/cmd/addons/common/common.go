// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package common

import (
	"fmt"
	"log/slog"

	"github.com/siemens-healthineers/k2s/internal/terminal"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/internal/addons"

	"github.com/samber/lo"
)

type addonInfos struct{ allAddons addons.Addons }

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

func LogAddons(allAddons addons.Addons) {
	slog.Debug("addons loaded", "count", len(allAddons), "addons", addonInfos{allAddons})
}

// LogValue is a slog.LogValuer implementation to defer the construction of a parameter until the verbosity level is determined
func (ai addonInfos) LogValue() slog.Value {
	infos := lo.Map(ai.allAddons, func(a addons.Addon, _ int) struct{ Name, Directory string } {
		return struct{ Name, Directory string }{Name: a.Metadata.Name, Directory: a.Directory}
	})

	return slog.AnyValue(infos)
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
