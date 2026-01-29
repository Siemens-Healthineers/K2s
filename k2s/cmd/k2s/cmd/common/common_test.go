// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package common

import (
	"log/slog"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/contracts/config"
)

func Test(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "cmd common Unit Tests", Label("unit", "ci", "cmd"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("common", func() {
	Describe("CmdFailure", func() {
		Describe("Error", func() {
			It("implements the error interface", func() {
				sut := &CmdFailure{
					Code:    "my-code",
					Message: "my-msg",
				}

				result := sut.Error()

				Expect(result).To(Equal("my-code: my-msg"))
			})
		})
	})

	Describe("FailureSeverity", func() {
		DescribeTable("String - implements the stringer interface", func(input FailureSeverity, expected string) {
			sut := FailureSeverity(input)

			result := sut.String()

			Expect(result).To(Equal(expected))
		},
			Entry("warning", FailureSeverity(3), "warning"),
			Entry("error", FailureSeverity(4), "error"),
			Entry("unknown", FailureSeverity(123), "unknown"))
	})

	Describe("CreateSystemNotInstalledCmdResult", func() {
		It("works", func() {
			result := CreateSystemNotInstalledCmdResult()

			Expect(result.Failure.Code).To(Equal(config.ErrSystemNotInstalled.Error()))
		})
	})

	Describe("CreateSystemNotInstalledCmdFailure", func() {
		It("works", func() {
			result := CreateSystemNotInstalledCmdFailure()

			Expect(result.Severity).To(Equal(SeverityWarning))
			Expect(result.Code).To(Equal(config.ErrSystemNotInstalled.Error()))
			Expect(result.Message).To(Equal(ErrSystemNotInstalledMsg))
		})
	})
})
