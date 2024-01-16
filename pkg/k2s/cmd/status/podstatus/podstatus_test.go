// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package podstatus

import (
	"testing"

	"k2s/cmd/status/load"

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

func TestPodstatus(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "podstatus Unit Tests", Label("unit"))
}

var _ = Describe("podstatus", func() {
	Describe("PrintPodStatus", func() {
		It("prints pods", func() {
			headerRowsCount := 1
			printer := &testTerminalPrinter{}
			pods := []load.Pod{{}, {}, {}}
			expectedRowsCount := headerRowsCount + len(pods)
			sut := NewPodStatusPrinter(printer)

			sut.PrintPodStatus(pods, false)

			Expect(len(printer.log)).To(BeNumerically(">=", 1))
			Expect(printer.log[0].logType).To(Equal(itemsLogType))

			table := printer.log[0].value.([][]string)

			Expect(table).To(HaveLen(expectedRowsCount))
		})

		When("additional info flag is false", func() {
			It("prints standard headers only", func() {
				expectedRowsCountWithHeaders := 1
				expectedColumnsCount := 5
				printer := &testTerminalPrinter{}
				sut := NewPodStatusPrinter(printer)

				sut.PrintPodStatus([]load.Pod{}, false)

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
				expectedColumnsCount := 8
				printer := &testTerminalPrinter{}
				sut := NewPodStatusPrinter(printer)

				sut.PrintPodStatus([]load.Pod{}, true)

				Expect(len(printer.log)).To(BeNumerically(">=", 1))
				Expect(printer.log[0].logType).To(Equal(itemsLogType))

				table := printer.log[0].value.([][]string)

				Expect(table).To(HaveLen(expectedRowsCountWithHeaders))
				Expect(table[0]).To(HaveLen(expectedColumnsCount))
			})
		})

		It("prints the table", func() {
			rowsCountWithHeaders := 1
			pods := []load.Pod{{}, {}, {}}
			expectedLen := rowsCountWithHeaders + len(pods)
			printer := &testTerminalPrinter{}
			sut := NewPodStatusPrinter(printer)

			sut.PrintPodStatus(pods, false)

			Expect(len(printer.log)).To(BeNumerically(">=", 1))
			Expect(printer.log[0].logType).To(Equal(itemsLogType))

			table := printer.log[0].value.([][]string)

			Expect(table).To(HaveLen(expectedLen))
		})

		When("all Pods running", func() {
			It("prints success", func() {
				printer := &testTerminalPrinter{}
				pods := []load.Pod{
					{IsRunning: true},
					{IsRunning: true},
				}
				sut := NewPodStatusPrinter(printer)

				sut.PrintPodStatus(pods, false)

				Expect(printer.log).To(HaveLen(3))
				Expect(printer.log[1].logType).To(Equal(successLogType))

				logs := printer.log[1].value.([]any)
				logText := logs[0].(string)

				Expect(logText).To(ContainSubstring("Pods are running"))
			})
		})

		When("not all Pods running", func() {
			It("prints warning", func() {
				printer := &testTerminalPrinter{}
				pods := []load.Pod{
					{IsRunning: true},
					{IsRunning: false},
				}
				sut := NewPodStatusPrinter(printer)

				sut.PrintPodStatus(pods, false)

				Expect(printer.log).To(HaveLen(3))
				Expect(printer.log[1].logType).To(Equal(warningLogType))

				logs := printer.log[1].value.([]any)
				logText := logs[0].(string)

				Expect(logText).To(ContainSubstring("Pods are not running"))
			})
		})
	})

	Describe("createHeaders", func() {
		When("additional info flag is false", func() {
			It("creates standard headers only", func() {
				expected := []string{"STATUS", "NAME", "READY", "RESTARTS", "AGE"}

				actual := createHeaders(false)

				Expect(actual).To(HaveExactElements(expected))
			})
		})

		When("additional info flag is true", func() {
			It("creates standard headers only", func() {
				expected := []string{"STATUS", "NAMESPACE", "NAME", "READY", "RESTARTS", "AGE", "IP", "NODE"}

				actual := createHeaders(true)

				Expect(actual).To(HaveExactElements(expected))
			})
		})
	})

	Describe("buildRows", func() {
		Context("no Pods", func() {
			It("returns empty, positive result", func() {
				pods := []load.Pod{}
				sut := NewPodStatusPrinter(nil)

				rows, ready := sut.buildRows(pods, false)

				Expect(rows).To(BeEmpty())
				Expect(ready).To(BeTrue())
			})
		})

		It("creates one row per Pod item", func() {
			pods := []load.Pod{
				{IsRunning: true},
				{IsRunning: false},
			}
			expectedLen := len(pods)
			sut := NewPodStatusPrinter(&testTerminalPrinter{})

			rows, _ := sut.buildRows(pods, false)

			Expect(rows).To(HaveLen(expectedLen))
		})

		When("all Pods running", func() {
			It("returns positive result", func() {
				pods := []load.Pod{
					{IsRunning: true},
					{IsRunning: true},
				}
				sut := NewPodStatusPrinter(&testTerminalPrinter{})

				_, ready := sut.buildRows(pods, false)

				Expect(ready).To(BeTrue())
			})
		})

		When("not all Pods running", func() {
			It("returns negative result", func() {
				pods := []load.Pod{
					{IsRunning: true},
					{IsRunning: false},
				}
				sut := NewPodStatusPrinter(&testTerminalPrinter{})

				_, ready := sut.buildRows(pods, false)

				Expect(ready).To(BeFalse())
			})
		})
	})

	Describe("buildRow", func() {
		When("additional info flag is false", func() {
			It("builds standard columns only", func() {
				expectedColumnsLen := 5
				pod := load.Pod{
					Status:    "idle",
					Name:      "cool pod",
					Ready:     "yes",
					Restarts:  "32",
					Age:       "old",
					IsRunning: true,
				}
				printer := &testTerminalPrinter{}
				sut := NewPodStatusPrinter(printer)

				actual := sut.buildRow(pod, false)

				Expect(actual).To(HaveLen(expectedColumnsLen))

				Expect(actual[0]).To(Equal("Running"))
				Expect(actual[1]).To(Equal(pod.Name))
				Expect(actual[2]).To(Equal(pod.Ready))
				Expect(actual[3]).To(Equal(pod.Restarts))
				Expect(actual[4]).To(Equal(pod.Age))

				Expect(printer.greenPrinted).To(BeTrue())
			})
		})

		When("additional info flag is true", func() {
			It("builds all columns", func() {
				expectedColumnsLen := 8
				pod := load.Pod{
					Status:    "idle",
					Namespace: "cool namespace",
					Name:      "cool pod",
					Ready:     "yes",
					Restarts:  "32",
					Age:       "old",
					Ip:        "localhorst",
					Node:      "Linux",
				}
				printer := &testTerminalPrinter{}
				sut := NewPodStatusPrinter(printer)

				actual := sut.buildRow(pod, true)

				Expect(actual).To(HaveLen(expectedColumnsLen))

				Expect(actual[0]).To(Equal(pod.Status))
				Expect(actual[1]).To(Equal(pod.Namespace))
				Expect(actual[2]).To(Equal(pod.Name))
				Expect(actual[3]).To(Equal(pod.Ready))
				Expect(actual[4]).To(Equal(pod.Restarts))
				Expect(actual[5]).To(Equal(pod.Age))
				Expect(actual[6]).To(Equal(pod.Ip))
				Expect(actual[7]).To(Equal(pod.Node))

				Expect(printer.redPrinted).To(BeTrue())
			})
		})
	})
})
