// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package print

import (
	"errors"
	ct "k2s/providers/terminal/defs"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

type logEntry struct {
	logType string
	value   any
}

type testTerminalPrinter struct {
	log            []logEntry
	err            error
	tableString    string
	separatorParam string
	tableParam     [][]string
	spinner        any
}

type leveledList struct {
	text  string
	items []ct.LeveledListItem
}

type testSpinner struct {
}

const (
	newlineLogType     = "newline"
	leveledListLogType = "leveledList"
)

func (t *testTerminalPrinter) Println(m ...any) {
	t.log = append(t.log, logEntry{logType: newlineLogType})
}

func (t *testTerminalPrinter) SPrintTable(separator string, table [][]string) (string, error) {
	t.separatorParam = separator
	t.tableParam = table

	return t.tableString, t.err
}

func (t *testTerminalPrinter) PrintLeveledTreeListItems(rootText string, items []ct.LeveledListItem) {
	t.log = append(t.log, logEntry{logType: leveledListLogType, value: leveledList{text: rootText, items: items}})
}

func (t *testTerminalPrinter) StartSpinner(m ...any) (any, error) {
	return t.spinner, nil
}

func (s *testSpinner) Fail(m ...any) {
	// stub
}

func (s *testSpinner) Stop() error {
	return nil
}

func (t *testTerminalPrinter) PrintCyanFg(text string) string {
	return text
}

func TestAddons(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "addons print Unit Tests", Label("unit"))
}

var _ = Describe("print", func() {
	Describe("PrintAddons", func() {
		When("addon printing error occurred", func() {
			It("returns the error", func() {
				printer := &testTerminalPrinter{err: errors.New("oops")}
				sut := NewAddonsPrinter(printer)

				Expect(sut.PrintAddons([]string{}, []AddonPrintInfo{})).ToNot(Succeed())
			})
		})

		When("successful", func() {
			It("returns nil", func() {
				printer := &testTerminalPrinter{spinner: &testSpinner{}}
				sut := NewAddonsPrinter(printer)

				Expect(sut.PrintAddons([]string{}, []AddonPrintInfo{})).To(Succeed())
			})

			It("prints leveled list", func() {
				printer := &testTerminalPrinter{
					tableString: "addon1 | this is addon 1\naddon2 | this is addon 2\n$---$\naddon3 | this is addon 3",
				}
				sut := NewAddonsPrinter(printer)

				Expect(sut.PrintAddons(nil, nil)).To(Succeed())
				Expect(printer.log).To(HaveLen(2))

				leveledList := printer.log[1].value.(leveledList)

				Expect(leveledList.text).To(Equal("Addons"))
				Expect(leveledList.items).To(HaveLen(5))
			})
		})
	})

	Describe("buildIndentedList", func() {
		When("error occurred", func() {
			It("returns the error", func() {
				printer := &testTerminalPrinter{err: errors.New("oops")}
				sut := NewAddonsPrinter(printer)

				actual, err := sut.buildIndentedList(nil, nil)

				Expect(actual).To(BeNil())
				Expect(err).To(HaveOccurred())
			})
		})

		Context("nil params", func() {
			It("returns list with separator only", func() {
				printer := &testTerminalPrinter{tableString: separator}
				sut := NewAddonsPrinter(printer)

				actual, err := sut.buildIndentedList(nil, nil)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(HaveLen(1))
				Expect(actual[0]).To(Equal(separator))
			})
		})
	})

	Describe("buildLeveledList", func() {
		Context("nil addons list with enabled node only", func() {
			It("builds the correct list", func() {
				actual := buildLeveledList(nil)

				Expect(actual).To(HaveLen(1))
				Expect(actual[0].Level).To(Equal(0))
				Expect(actual[0].Text).To(Equal("Enabled"))
			})
		})

		Context("empty addons list with enabled node only", func() {
			It("builds the correct list", func() {
				actual := buildLeveledList([]string{})

				Expect(actual).To(HaveLen(1))
				Expect(actual[0].Level).To(Equal(0))
				Expect(actual[0].Text).To(Equal("Enabled"))
			})
		})

		Context("addon separator-only list with enabled/disabled node", func() {
			It("builds the correct list", func() {
				actual := buildLeveledList([]string{separator})

				Expect(actual).To(HaveLen(2))
				Expect(actual[0].Level).To(Equal(0))
				Expect(actual[0].Text).To(Equal("Enabled"))
				Expect(actual[1].Level).To(Equal(0))
				Expect(actual[1].Text).To(Equal("Disabled"))
			})
		})

		Context("enabled/disabled addons", func() {
			It("builds the correct list", func() {
				addons := []string{
					"addon1",
					separator,
					"addon2"}

				actual := buildLeveledList(addons)

				Expect(actual).To(HaveLen(4))
				Expect(actual[0].Level).To(Equal(0))
				Expect(actual[0].Text).To(Equal("Enabled"))
				Expect(actual[1].Level).To(Equal(1))
				Expect(actual[1].Text).To(Equal("addon1"))
				Expect(actual[2].Level).To(Equal(0))
				Expect(actual[2].Text).To(Equal("Disabled"))
				Expect(actual[3].Level).To(Equal(1))
				Expect(actual[3].Text).To(Equal("addon2"))
			})
		})
	})

	Describe("indentAddonsList", func() {
		When("error occurred", func() {
			It("returns the error", func() {
				printer := &testTerminalPrinter{err: errors.New("oops")}
				sut := NewAddonsPrinter(printer)

				actual, err := sut.indentAddonsList(nil)

				Expect(err).To(HaveOccurred())
				Expect(actual).To(BeNil())
			})
		})

		When("successful", func() {
			It("calls table printing correctly", func() {
				printer := &testTerminalPrinter{}
				addons := []AddonPrintInfo{
					{Name: "A1", Description: "D1"},
					{Name: "A2", Description: "D2"},
				}
				sut := NewAddonsPrinter(printer)

				_, err := sut.indentAddonsList(addons)

				Expect(err).ToNot(HaveOccurred())
				Expect(printer.separatorParam).To(Equal(" # "))

				table := printer.tableParam

				Expect(table).To(HaveLen(2))

				Expect(table[0]).To(HaveLen(2))
				Expect(table[0][0]).To(Equal(" A1"))
				Expect(table[0][1]).To(Equal("D1"))

				Expect(table[1]).To(HaveLen(2))
				Expect(table[1][0]).To(Equal(" A2"))
				Expect(table[1][1]).To(Equal("D2"))
			})

			It("splits table string correctly", func() {
				printer := &testTerminalPrinter{
					tableString: "A1 - D1\nA2 - D2\nA3 - D3\n",
				}
				sut := NewAddonsPrinter(printer)

				actual, err := sut.indentAddonsList(nil)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(HaveLen(3))
				Expect(actual[0]).To(Equal("A1 - D1"))
				Expect(actual[1]).To(Equal("A2 - D2"))
				Expect(actual[2]).To(Equal("A3 - D3"))
			})
		})
	})
})
