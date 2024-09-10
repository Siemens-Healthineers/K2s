// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package common

import (
	"fmt"
	"log/slog"
	"strings"

	"github.com/siemens-healthineers/k2s/internal/terminal"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/internal/core/addons"

	"github.com/samber/lo"
)

type addonInfos struct{ allAddons addons.Addons }

func ValidateAddonNames(allAddons addons.Addons, activity string, terminalPrinter terminal.TerminalPrinter, names ...string) error {
	for _, name := range names {
		splits := strings.Split(name, " ")

		found := false
		if len(splits) == 2 {
			addonName := splits[0]
			implName := splits[1]

			found = lo.ContainsBy(allAddons, func(addon addons.Addon) bool {
				addonFound := addon.Metadata.Name == addonName

				if addonFound && lo.ContainsBy(addon.Spec.Implementations, func(impl addons.Implementation) bool {
					return impl.Name == implName
				}) {
					return true
				}

				return false
			})
		} else if len(splits) < 2 {
			// in case there is no implementation specified
			found = lo.ContainsBy(allAddons, func(addon addons.Addon) bool {
				return addon.Metadata.Name == name
			})
		}

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
	infos := lo.Map(ai.allAddons, func(a addons.Addon, _ int) struct {
		Name            string
		Directory       string
		Implementations []string
	} {
		return struct {
			Name            string
			Directory       string
			Implementations []string
		}{Name: a.Metadata.Name, Directory: a.Directory, Implementations: lo.Map(a.Spec.Implementations, func(impl addons.Implementation, index int) string { return impl.Name })}
	})

	return slog.AnyValue(infos)
}

func printValidAddonNames(allAddons addons.Addons, terminalPrinter terminal.TerminalPrinter) {
	tableHeaders := []string{"Available addon names"}
	addonTable := [][]string{tableHeaders}

	for _, addon := range allAddons {
		for _, impl := range addon.Spec.Implementations {
			if addon.Metadata.Name != impl.Name {
				row := []string{string(addon.Metadata.Name + " " + impl.Name)}
				addonTable = append(addonTable, row)
			} else {
				row := []string{string(addon.Metadata.Name)}
				addonTable = append(addonTable, row)
			}
		}
	}
	terminalPrinter.PrintTableWithHeaders(addonTable)
}
