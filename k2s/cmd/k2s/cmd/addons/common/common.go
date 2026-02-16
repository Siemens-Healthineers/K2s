// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package common

import (
	"fmt"
	"log/slog"
	"sort"
	"strings"

	"github.com/siemens-healthineers/k2s/internal/terminal"

	"github.com/siemens-healthineers/k2s/internal/core/addons"

	"github.com/samber/lo"
)

type addonInfos struct{ allAddons addons.Addons }

func LogAddons(allAddons addons.Addons) {
	slog.Debug("addons loaded", "count", len(allAddons), "addons", addonInfos{allAddons})
}

// FindImplementation resolves an addon implementation based on command args.
//
// Supported forms:
//   - ["registry"] -> matches AddonsCmdName "registry"
//   - ["ingress", "nginx"] -> matches AddonsCmdName "ingress nginx"
func FindImplementation(allAddons addons.Addons, args []string) (addon addons.Addon, impl addons.Implementation, err error) {
	if len(args) < 1 || len(args) > 2 {
		return addon, impl, fmt.Errorf("expected ADDON [IMPLEMENTATION]")
	}

	cmdName := args[0]
	if len(args) == 2 {
		cmdName = args[0] + " " + args[1]
	}

	for _, a := range allAddons {
		for _, i := range a.Spec.Implementations {
			if strings.EqualFold(i.AddonsCmdName, cmdName) {
				return a, i, nil
			}
		}
	}

	valid := make([]string, 0)
	for _, a := range allAddons {
		for _, i := range a.Spec.Implementations {
			valid = append(valid, i.AddonsCmdName)
		}
	}
	sort.Strings(valid)

	return addon, impl, fmt.Errorf("unknown addon '%s' (valid: %s)", cmdName, strings.Join(valid, ", "))
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
