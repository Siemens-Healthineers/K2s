// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package runningstate_test

import (
	"k2s/cmd/status/load"
	rs "k2s/cmd/status/runningstate"
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
}

const (
	warningLogType = "warning"
	successLogType = "success"
	itemsLogType   = "items"
)

func (t *testTerminalPrinter) PrintSuccess(m ...any) {
	t.log = append(t.log, logEntry{logType: successLogType, value: m})
}

func (t *testTerminalPrinter) PrintWarning(m ...any) {
	t.log = append(t.log, logEntry{logType: warningLogType, value: m})
}

func (t *testTerminalPrinter) PrintTreeListItems(items []string) {
	t.log = append(t.log, logEntry{logType: itemsLogType, value: items})
}

func TestRunningstate(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "runningstate Unit Tests", Label("unit"))
}

var _ = Describe("runningstate", func() {
	Describe("PrintRunningState", func() {
		When("cluster is running", func() {
			It("logs success and proceeds", func() {
				printer := &testTerminalPrinter{log: []logEntry{}}
				state := load.RunningState{IsRunning: true}
				sut := rs.NewRunningStatePrinter(printer)

				actual := sut.PrintRunningState(state)

				Expect(actual).To(BeTrue())
				Expect(printer.log).To(HaveLen(1))
				Expect(printer.log[0].logType).To(Equal(successLogType))
				Expect(printer.log[0].value.([]any)[0]).To(ContainSubstring("cluster is running"))
			})
		})

		When("cluster is not running", func() {
			It("logs warning and does not proceed", func() {
				printer := &testTerminalPrinter{log: []logEntry{}}
				state := load.RunningState{IsRunning: false}
				sut := rs.NewRunningStatePrinter(printer)

				actual := sut.PrintRunningState(state)

				Expect(actual).To(BeFalse())
				Expect(printer.log).To(HaveLen(2))
				Expect(printer.log[0].logType).To(Equal(warningLogType))
				Expect(printer.log[0].value.([]any)[0]).To(ContainSubstring("cluster is not running"))
			})

			It("prints the issue", func() {
				expected := []string{"problem-1", "problem-2"}
				state := load.RunningState{IsRunning: false, Issues: expected}
				printer := &testTerminalPrinter{log: []logEntry{}}
				sut := rs.NewRunningStatePrinter(printer)

				sut.PrintRunningState(state)

				Expect(printer.log).To(HaveLen(2))
				Expect(printer.log[1].logType).To(Equal(itemsLogType))

				items := printer.log[1].value.([]string)

				Expect(items).To(HaveExactElements(expected))
			})
		})
	})
})
