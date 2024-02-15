// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package print

import (
	"fmt"
	"k2s/addons/print/json"
	"k2s/providers/marshalling"
	"k2s/providers/terminal"
	t "k2s/providers/terminal/defs"
	"strings"

	"github.com/samber/lo"
)

type TerminalPrinter interface {
	Println(m ...any)
	SPrintTable(separator string, table [][]string) (string, error)
	PrintLeveledTreeListItems(rootText string, items []t.LeveledListItem)
	PrintCyanFg(text string) string
}

type AddonsPrinter struct {
	terminalPrinter TerminalPrinter
}

type AddonsJsonPrinter struct {
	terminalPrinter TerminalPrinter
	jsonPrinter     json.JsonPrinter
}

type AddonPrintInfo struct {
	Name        string
	Description string
}

const separator = "$---$"

func NewAddonsPrinter(terminalPrinter TerminalPrinter) AddonsPrinter {
	return AddonsPrinter{
		terminalPrinter: terminalPrinter,
	}
}

func NewAddonsJsonPrinter() AddonsJsonPrinter {
	terminalPrinter := terminal.NewTerminalPrinter()
	jsonMarshaller := marshalling.NewJsonMarshaller()

	return AddonsJsonPrinter{
		terminalPrinter: terminalPrinter,
		jsonPrinter:     json.NewJsonPrinter(terminalPrinter, jsonMarshaller),
	}
}

func (p AddonsPrinter) PrintAddons(enabledAddonNames []string, addons []AddonPrintInfo) error {
	p.terminalPrinter.Println()
	indentedList, err := p.buildIndentedList(enabledAddonNames, addons)
	if err != nil {
		return err
	}

	leveledList := buildLeveledList(indentedList)

	p.terminalPrinter.PrintLeveledTreeListItems("Addons", leveledList)

	return nil
}

func (p AddonsJsonPrinter) PrintAddons(enabledAddonNames []string, disabledAddonNames []string) error {
	addons := &json.Addons{EnabledAddons: enabledAddonNames, DisabledAddons: disabledAddonNames}
	return p.jsonPrinter.PrintJson(addons)
}

func (p AddonsPrinter) buildIndentedList(enabledAddonNames []string, addons []AddonPrintInfo) ([]string, error) {
	enabledAddons := lo.Filter(addons, func(addon AddonPrintInfo, _ int) bool {
		return lo.Contains(enabledAddonNames, addon.Name)
	})

	addonsToPrint := append(enabledAddons, AddonPrintInfo{Name: separator})
	addonsToPrint = lo.Union(addonsToPrint, addons)

	list, err := p.indentAddonsList(addonsToPrint)
	if err != nil {
		return nil, err
	}

	return list, nil
}

func buildLeveledList(addonsList []string) []t.LeveledListItem {
	list := []t.LeveledListItem{{Level: 0, Text: "Enabled"}}

	for _, row := range addonsList {
		if strings.Contains(row, separator) {
			list = append(list, t.LeveledListItem{Level: 0, Text: "Disabled"})
		} else {
			list = append(list, t.LeveledListItem{Level: 1, Text: row})
		}
	}

	return list
}

func (p AddonsPrinter) indentAddonsList(addons []AddonPrintInfo) ([]string, error) {
	table := [][]string{}

	for _, addon := range addons {
		addonName := p.terminalPrinter.PrintCyanFg(addon.Name)
		row := []string{fmt.Sprintf(" %s", addonName), addon.Description}

		table = append(table, row)
	}

	tableString, err := p.terminalPrinter.SPrintTable(" # ", table)
	if err != nil {
		return nil, err
	}

	filter := func(r rune) bool { return r == rune(10) } // split by '\n'
	rows := strings.FieldsFunc(tableString, filter)

	return rows, nil
}
