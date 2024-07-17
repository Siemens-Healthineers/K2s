// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package print

import (
	"fmt"
	"strings"

	"github.com/siemens-healthineers/k2s/internal/addons"
	"github.com/siemens-healthineers/k2s/internal/json"

	"github.com/samber/lo"
)

type TerminalPrinter interface {
	Println(m ...any)
	SPrintTable(separator string, table [][]string) (string, error)
	PrintLeveledTreeListItems(rootText string, items []struct {
		Level int
		Text  string
	})
	PrintCyanFg(text string) string
}

type AddonsPrinter struct {
	terminalPrinter TerminalPrinter
}

type Addon struct {
	Name            string   `json:"name"`
	Description     string   `json:"description"`
	Implementations []string `json:"implementations"`
}

type printList struct {
	EnabledAddons  []Addon `json:"enabledAddons"`
	DisabledAddons []Addon `json:"disabledAddons"`
}

const separator = "$---$"

func NewAddonsPrinter(terminalPrinter TerminalPrinter) AddonsPrinter {
	return AddonsPrinter{
		terminalPrinter: terminalPrinter,
	}
}

func (p AddonsPrinter) PrintAddonsUserFriendly(enabledAddons []Addon, allAddons addons.Addons) error {
	p.terminalPrinter.Println()

	list := toPrintList(enabledAddons, allAddons)

	indentedList, err := p.indentList(list)
	if err != nil {
		return err
	}

	leveledList := buildLeveledList(indentedList)

	p.terminalPrinter.PrintLeveledTreeListItems("Addons", leveledList)

	return nil
}

func (p AddonsPrinter) PrintAddonsAsJson(enabledAddonNames []Addon, allAddons addons.Addons) error {
	list := toPrintList(enabledAddonNames, allAddons)

	bytes, err := json.MarshalIndent(list)
	if err != nil {
		return fmt.Errorf("error happened during list images: %w", err)
	}

	p.terminalPrinter.Println(string(bytes))

	return nil
}

func toPrintList(enabledAddonsList []Addon, allAddons addons.Addons) *printList {
	var enabledAddons []Addon
	var disabledAddons []Addon

	for _, a := range allAddons {
		addon := Addon{
			Name:            a.Metadata.Name,
			Description:     a.Metadata.Description,
			Implementations: lo.Map(a.Spec.Implementations, func(e addons.Implementation, _ int) string { return e.Name }),
		}

		if lo.Contains(lo.Map(enabledAddonsList, func(e Addon, _ int) string { return e.Name }), addon.Name) {
			enabledImplementations := lo.Filter(enabledAddonsList, func(item Addon, _ int) bool { return item.Name == addon.Name })[0].Implementations
			disabledImplementations := lo.Without(addon.Implementations, enabledImplementations...)
			addon.Implementations = enabledImplementations
			enabledAddons = append(enabledAddons, addon)

			// In case not all implementations of the addon are enabled, add still disabled ones to disabled section
			if len(disabledImplementations) > 0 {
				addon.Implementations = disabledImplementations
				disabledAddons = append(disabledAddons, addon)
			}

		} else {
			disabledAddons = append(disabledAddons, addon)
		}
	}

	return &printList{
		EnabledAddons:  enabledAddons,
		DisabledAddons: disabledAddons,
	}
}

func (p AddonsPrinter) indentList(list *printList) ([]string, error) {
	table := [][]string{}
	table = append(table, p.createRows(list.EnabledAddons)...)
	table = append(table, []string{separator})
	table = append(table, p.createRows(list.DisabledAddons)...)

	tableString, err := p.terminalPrinter.SPrintTable(" # ", table)
	if err != nil {
		return nil, err
	}

	filter := func(r rune) bool { return r == rune(10) } // split by '\n'
	rows := strings.FieldsFunc(tableString, filter)

	return rows, nil
}

func (p AddonsPrinter) createRows(addons []Addon) [][]string {
	rows := [][]string{}

	for _, addon := range addons {
		addonName := p.terminalPrinter.PrintCyanFg(addon.Name)
		row := []string{fmt.Sprintf(" %s", addonName), addon.Description}
		rows = append(rows, row)
		for _, implementation := range addon.Implementations {
			if implementation != addon.Name {
				implementation := p.terminalPrinter.PrintCyanFg(implementation)
				implementationRow := []string{fmt.Sprintf("$implementation$ %s", implementation)}
				rows = append(rows, implementationRow)
			}
		}
	}

	return rows
}

func buildLeveledList(addonsList []string) []struct {
	Level int
	Text  string
} {
	list := []struct {
		Level int
		Text  string
	}{{Level: 0, Text: "Enabled"}}

	for _, row := range addonsList {
		if strings.Contains(row, separator) {
			list = append(list, struct {
				Level int
				Text  string
			}{Level: 0, Text: "Disabled"})
		} else if strings.Contains(row, "$implementation$") {
			row = strings.Replace(row, "$implementation$", "", 1)
			list = append(list, struct {
				Level int
				Text  string
			}{Level: 2, Text: row})
		} else {
			list = append(list, struct {
				Level int
				Text  string
			}{Level: 1, Text: row})
		}
	}

	return list
}
