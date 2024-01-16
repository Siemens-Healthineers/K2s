// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package setuptype_test

import (
	"k2s/cmd/status/load"
	st "k2s/cmd/status/setuptype"
	"testing"

	u "k2s/utils/strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

type logEntry struct {
	logType string
	value   []string
}

type testTerminalPrinter struct {
	log []logEntry
}

const (
	newlineLogType = "newline"
	warningLogType = "warning"
	textLogType    = "text"
)

func (t *testTerminalPrinter) Println(m ...any) {
	if len(m) == 0 {
		t.log = append(t.log, logEntry{logType: newlineLogType})
	} else {
		t.log = append(t.log, logEntry{logType: textLogType, value: u.ToStrings(m...)})
	}
}

func (t *testTerminalPrinter) PrintWarning(m ...any) {
	t.log = append(t.log, logEntry{logType: warningLogType, value: u.ToStrings(m...)})
}

func (t *testTerminalPrinter) PrintCyanFg(text string) string {
	return text
}

func TestSetuptype(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "setuptype Unit Tests", Label("unit"))
}

var _ = Describe("setuptype", func() {
	Describe("PrintSetupType", func() {
		When("invalid setup type found", func() {
			It("prints validation error, invalid setup type and does not proceed", func() {
				setupType := load.SetupType{Name: "InvalidType", ValidationError: "this is invalid"}
				printer := &testTerminalPrinter{
					log: []logEntry{},
				}
				sut := st.NewSetupTypePrinter(printer)

				actual := sut.PrintSetupType(setupType)

				Expect(actual).To(BeFalse())

				Expect(printer.log).To(HaveLen(2))

				Expect(printer.log[0].logType).To(Equal(warningLogType))
				Expect(printer.log[0].value).To(HaveLen(1))

				Expect(printer.log[0].value[0]).To(SatisfyAll(
					ContainSubstring("InvalidType"),
					ContainSubstring("is invalid"),
				))

				Expect(printer.log[1].logType).To(Equal(newlineLogType))
				Expect(printer.log[1].value).To(HaveLen(0))
			})
		})

		When("no setup type found", func() {
			It("prints validation error and does not proceed", func() {
				setupType := load.SetupType{ValidationError: "this is invalid"}
				printer := &testTerminalPrinter{
					log: []logEntry{},
				}
				sut := st.NewSetupTypePrinter(printer)

				actual := sut.PrintSetupType(setupType)

				Expect(actual).To(BeFalse())

				Expect(printer.log).To(HaveLen(2))

				Expect(printer.log[0].logType).To(Equal(warningLogType))
				Expect(printer.log[0].value).To(HaveLen(1))

				Expect(printer.log[0].value[0]).To(ContainSubstring("is invalid"))

				Expect(printer.log[1].logType).To(Equal(newlineLogType))
				Expect(printer.log[1].value).To(HaveLen(0))
			})
		})

		When("not Linux-only", func() {
			It("prints setup type and version", func() {
				setupType := load.SetupType{Name: "ValidType", Version: "v1.2.3"}
				printer := &testTerminalPrinter{
					log: []logEntry{},
				}
				sut := st.NewSetupTypePrinter(printer)

				actual := sut.PrintSetupType(setupType)

				Expect(actual).To(BeTrue())

				Expect(printer.log).To(HaveLen(1))

				Expect(printer.log[0].logType).To(Equal(textLogType))
				Expect(printer.log[0].value).To(HaveLen(1))

				Expect(printer.log[0].value[0]).To(SatisfyAll(
					ContainSubstring("ValidType"),
					ContainSubstring("v1.2.3"),
				))
			})
		})

		When("Linux-only", func() {
			It("prints setup type and Linux-only hint", func() {
				setupType := load.SetupType{Name: "ValidType", LinuxOnly: true}
				printer := &testTerminalPrinter{
					log: []logEntry{},
				}
				sut := st.NewSetupTypePrinter(printer)

				actual := sut.PrintSetupType(setupType)

				Expect(actual).To(BeTrue())

				Expect(printer.log).To(HaveLen(1))

				Expect(printer.log[0].logType).To(Equal(textLogType))
				Expect(printer.log[0].value).To(HaveLen(1))

				Expect(printer.log[0].value[0]).To(ContainSubstring("ValidType (Linux-only)"))
			})
		})
	})
})
