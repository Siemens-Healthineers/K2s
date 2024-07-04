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

type addon struct {
	Name           string `json:"name"`
	Description    string `json:"description"`
	Implementation string `json:"implementation"`
}

type printList struct {
	EnabledAddons  []addon `json:"enabledAddons"`
	DisabledAddons []addon `json:"disabledAddons"`
}

const separator = "$---$"

func NewAddonsPrinter(terminalPrinter TerminalPrinter) AddonsPrinter {
	return AddonsPrinter{
		terminalPrinter: terminalPrinter,
	}
}

func (p AddonsPrinter) PrintAddonsUserFriendly(enabledAddonNames []string, allAddons addons.Addons) error {
	p.terminalPrinter.Println()

	list := toPrintList(enabledAddonNames, allAddons)

	indentedList, err := p.indentList(list)
	if err != nil {
		return err
	}

	leveledList := buildLeveledList(indentedList)

	p.terminalPrinter.PrintLeveledTreeListItems("Addons", leveledList)

	return nil
}

func (p AddonsPrinter) PrintAddonsAsJson(enabledAddonNames []string, allAddons addons.Addons) error {
	list := toPrintList(enabledAddonNames, allAddons)

	bytes, err := json.MarshalIndent(list)
	if err != nil {
		return fmt.Errorf("error happened during list images: %w", err)
	}

	p.terminalPrinter.Println(string(bytes))

	return nil
}

func toPrintList(enabledAddonNames []string, allAddons addons.Addons) *printList {
	var enabledAddons []addon
	var disabledAddons []addon

	for _, a := range allAddons {
		addon := addon{
			Name:        a.Metadata.Name,
			Description: a.Metadata.Description,
		}

		if lo.Contains(enabledAddonNames, addon.Name) {
			enabledAddons = append(enabledAddons, addon)
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

func (p AddonsPrinter) createRows(addons []addon) [][]string {
	rows := [][]string{}

	for _, addon := range addons {
		addonName := p.terminalPrinter.PrintCyanFg(addon.Name)
		row := []string{fmt.Sprintf(" %s", addonName), addon.Description}
		rows = append(rows, row)
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
		} else {
			list = append(list, struct {
				Level int
				Text  string
			}{Level: 1, Text: row})
		}
	}

	return list
}
