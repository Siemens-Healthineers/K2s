// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package print

import (
	"fmt"
	"k2s/providers/marshalling"
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

type AddonPrintInfo struct {
	Name        string
	Description string
}

type AddonsStatus struct {
	EnabledAddons  []AddonPrintInfo `json:"enabledAddons"`
	DisabledAddons []AddonPrintInfo `json:"disabledAddons"`
}

const separator = "$---$"

func NewAddonsPrinter(terminalPrinter TerminalPrinter) AddonsPrinter {
	return AddonsPrinter{
		terminalPrinter: terminalPrinter,
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

func (p AddonsPrinter) PrintAddonsAsJson(enabledAddonNames []string, addons []AddonPrintInfo) error {
	var enabledAddons []AddonPrintInfo
	var disabledAddons []AddonPrintInfo

	for _, a := range addons {
		if lo.Contains(enabledAddonNames, a.Name) {
			enabledAddons = append(enabledAddons, AddonPrintInfo{Name: a.Name, Description: a.Description})
		} else {
			disabledAddons = append(disabledAddons, AddonPrintInfo{Name: a.Name, Description: a.Description})
		}
	}

	addonsStatus := &AddonsStatus{EnabledAddons: enabledAddons, DisabledAddons: disabledAddons}

	jsonMarshaller := marshalling.NewJsonMarshaller()
	bytes, err := jsonMarshaller.MarshalIndent(addonsStatus)
	if err != nil {
		return fmt.Errorf("error happened during list images: %w", err)
	}

	p.terminalPrinter.Println(string(bytes))

	return nil
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
