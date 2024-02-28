// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package nodestatus

import (
	"k2s/cmd/status/common"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

type logEntry struct {
	logType string
	value   any
}

type testTerminalPrinter struct {
	log []logEntry

	redPrinted   bool
	greenPrinted bool
}

const (
	newlineLogType = "newline"
	warningLogType = "warning"
	successLogType = "success"
	itemsLogType   = "items"
)

func (t *testTerminalPrinter) PrintTableWithHeaders(table [][]string) {
	t.log = append(t.log, logEntry{logType: itemsLogType, value: table})
}

func (t *testTerminalPrinter) Println(m ...any) {
	t.log = append(t.log, logEntry{logType: newlineLogType})
}

func (t *testTerminalPrinter) PrintSuccess(m ...any) {
	t.log = append(t.log, logEntry{logType: successLogType, value: m})
}

func (t *testTerminalPrinter) PrintWarning(m ...any) {
	t.log = append(t.log, logEntry{logType: warningLogType, value: m})
}

func (t *testTerminalPrinter) PrintRedFg(text string) string {
	t.redPrinted = true

	return text
}

func (t *testTerminalPrinter) PrintGreenFg(text string) string {
	t.greenPrinted = true

	return text
}

func TestNodestatus(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "nodestatus Unit Tests", Label("unit", "ci"))
}

var _ = Describe("nodestatus", func() {
	Describe("PrintNodeStatus", func() {
		When("at least one node not ready", func() {
			It("does not proceed", func() {
				printer := &testTerminalPrinter{}
				nodes := []common.Node{
					{IsReady: true},
					{IsReady: false},
				}
				sut := NewNodeStatusPrinter(printer)

				actual := sut.PrintNodeStatus(nodes, false)

				Expect(actual).To(BeFalse())
			})

			It("prints a warning", func() {
				printer := &testTerminalPrinter{}
				nodes := []common.Node{
					{IsReady: true},
					{IsReady: false},
					{IsReady: true},
				}
				sut := NewNodeStatusPrinter(printer)

				sut.PrintNodeStatus(nodes, false)

				Expect(printer.log).To(HaveLen(3))
				Expect(printer.log[1].logType).To(Equal(warningLogType))

				logs := printer.log[1].value.([]any)
				logText := logs[0].(string)

				Expect(logText).To(ContainSubstring("nodes are not ready"))
			})
		})

		When("all nodes ready", func() {
			It("proceeds", func() {
				printer := &testTerminalPrinter{}
				nodes := []common.Node{
					{IsReady: true},
					{IsReady: true},
				}
				sut := NewNodeStatusPrinter(printer)

				actual := sut.PrintNodeStatus(nodes, false)

				Expect(actual).To(BeTrue())
			})

			It("prints success", func() {
				printer := &testTerminalPrinter{}
				nodes := []common.Node{
					{IsReady: true},
					{IsReady: true},
				}
				sut := NewNodeStatusPrinter(printer)

				sut.PrintNodeStatus(nodes, false)

				Expect(printer.log).To(HaveLen(3))
				Expect(printer.log[1].logType).To(Equal(successLogType))

				logs := printer.log[1].value.([]any)
				logText := logs[0].(string)

				Expect(logText).To(ContainSubstring("nodes are ready"))
			})
		})

		When("additional info flag is false", func() {
			It("prints standard headers only", func() {
				expectedRowsCountWithHeaders := 1
				expectedColumnsCount := 5
				printer := &testTerminalPrinter{}
				sut := NewNodeStatusPrinter(printer)

				sut.PrintNodeStatus([]common.Node{}, false)

				Expect(len(printer.log)).To(BeNumerically(">=", 1))
				Expect(printer.log[0].logType).To(Equal(itemsLogType))

				table := printer.log[0].value.([][]string)

				Expect(table).To(HaveLen(expectedRowsCountWithHeaders))
				Expect(table[0]).To(HaveLen(expectedColumnsCount))
			})
		})

		When("additional info flag is true", func() {
			It("prints all headers", func() {
				expectedRowsCountWithHeaders := 1
				expectedColumnsCount := 9
				printer := &testTerminalPrinter{}
				sut := NewNodeStatusPrinter(printer)

				sut.PrintNodeStatus([]common.Node{}, true)

				Expect(len(printer.log)).To(BeNumerically(">=", 1))
				Expect(printer.log[0].logType).To(Equal(itemsLogType))

				table := printer.log[0].value.([][]string)

				Expect(table).To(HaveLen(expectedRowsCountWithHeaders))
				Expect(table[0]).To(HaveLen(expectedColumnsCount))
			})
		})

		When("success", func() {
			It("table gets printed", func() {
				nodeItems := []common.Node{{}, {}, {}}
				expectedRowsCountWithHeaders := 1
				expectedCount := expectedRowsCountWithHeaders + len(nodeItems)
				printer := &testTerminalPrinter{}
				sut := NewNodeStatusPrinter(printer)

				sut.PrintNodeStatus(nodeItems, false)

				Expect(len(printer.log)).To(BeNumerically(">=", 1))
				Expect(printer.log[0].logType).To(Equal(itemsLogType))

				table := printer.log[0].value.([][]string)

				Expect(table).To(HaveLen(expectedCount))
			})
		})
	})

	Describe("createHeaders", func() {
		When("additional info flag is false", func() {
			It("creates standard headers only", func() {
				expected := []string{"STATUS", "NAME", "ROLE", "AGE", "VERSION"}

				actual := createHeaders(false)

				Expect(actual).To(HaveExactElements(expected))
			})
		})

		When("additional info flag is true", func() {
			It("creates all headers", func() {
				expected := []string{"STATUS", "NAME", "ROLE", "AGE", "VERSION", "INTERNAL-IP", "OS-IMAGE", "KERNEL-VERSION", "CONTAINER-RUNTIME"}

				actual := createHeaders(true)

				Expect(actual).To(HaveExactElements(expected))
			})
		})
	})

	Describe("buildRows", func() {
		Context("no nodes", func() {
			It("returns empty, positive result", func() {
				nodes := []common.Node{}
				sut := NewNodeStatusPrinter(nil)

				rows, ready := sut.buildRows(nodes, false)

				Expect(rows).To(BeEmpty())
				Expect(ready).To(BeTrue())
			})
		})

		It("creates one row per node item", func() {
			nodes := []common.Node{
				{IsReady: true},
				{IsReady: false},
				{IsReady: true},
			}
			expected := len(nodes)
			sut := NewNodeStatusPrinter(&testTerminalPrinter{})

			rows, _ := sut.buildRows(nodes, false)

			Expect(rows).To(HaveLen(expected))
		})

		When("all nodes ready", func() {
			It("returns positive result", func() {
				nodes := []common.Node{
					{IsReady: true},
					{IsReady: true},
				}
				sut := NewNodeStatusPrinter(&testTerminalPrinter{})

				_, ready := sut.buildRows(nodes, false)

				Expect(ready).To(BeTrue())
			})
		})

		When("not all nodes ready", func() {
			It("returns negative result", func() {
				nodes := []common.Node{
					{IsReady: true},
					{IsReady: false},
					{IsReady: true},
				}
				sut := NewNodeStatusPrinter(&testTerminalPrinter{})

				_, ready := sut.buildRows(nodes, false)

				Expect(ready).To(BeFalse())
			})
		})
	})

	Describe("buildRow", func() {
		Context("standard columns", func() {
			It("returns correct row", func() {
				expectedColumnsCount := 5
				node := common.Node{
					Status:         "Ready :-)",
					IsReady:        true,
					KubeletVersion: "1.2.3",
					Name:           "super node",
					Role:           "VIN",
					Age:            "4d0h23m",
				}
				printer := &testTerminalPrinter{}
				sut := NewNodeStatusPrinter(printer)

				actual := sut.buildRow(node, false)

				Expect(actual).To(HaveLen(expectedColumnsCount))

				Expect(actual[0]).To(Equal(node.Status))
				Expect(actual[1]).To(Equal(node.Name))
				Expect(actual[2]).To(Equal(node.Role))
				Expect(actual[3]).To(Equal(node.Age))
				Expect(actual[4]).To(Equal(node.KubeletVersion))

				Expect(printer.greenPrinted).To(BeTrue())
			})
		})

		Context("with additional columns", func() {
			It("returns correct row", func() {
				expectedColumnsCount := 9
				node := common.Node{
					IsReady:          false,
					InternalIp:       "localhost",
					OsImage:          "Kali Linux",
					KernelVersion:    "42",
					ContainerRuntime: "CRY-OH",
				}
				printer := &testTerminalPrinter{}
				sut := NewNodeStatusPrinter(printer)

				actual := sut.buildRow(node, true)

				Expect(actual).To(HaveLen(expectedColumnsCount))

				Expect(actual[5]).To(Equal(node.InternalIp))
				Expect(actual[6]).To(Equal(node.OsImage))
				Expect(actual[7]).To(Equal(node.KernelVersion))
				Expect(actual[8]).To(Equal(node.ContainerRuntime))

				Expect(printer.redPrinted).To(BeTrue())
			})
		})
	})
})
