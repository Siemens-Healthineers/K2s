// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package common

import (
	"log/slog"
	"testing"

	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"
	"github.com/siemens-healthineers/k2s/internal/powershell"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
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

			Expect(result.Failure.Code).To(Equal(setupinfo.ErrSystemNotInstalled.Error()))
		})
	})

	Describe("CreateSystemNotInstalledCmdFailure", func() {
		It("works", func() {
			result := CreateSystemNotInstalledCmdFailure()

			Expect(result.Severity).To(Equal(SeverityWarning))
			Expect(result.Code).To(Equal(setupinfo.ErrSystemNotInstalled.Error()))
			Expect(result.Message).To(Equal(ErrSystemNotInstalledMsg))
		})
	})

	Describe("DeterminePsVersion", func() {
		When("setup type is multivm including Windows node", func() {
			It("determines PowerShell v7", func() {
				config := &setupinfo.Config{
					SetupName: setupinfo.SetupNameMultiVMK8s,
					LinuxOnly: false,
				}

				actual := DeterminePsVersion(config)

				Expect(actual).To(Equal(powershell.PowerShellV7))
			})
		})

		When("setup type is multivm Linux-only", func() {
			It("determines PowerShell v5", func() {
				config := &setupinfo.Config{
					SetupName: setupinfo.SetupNameMultiVMK8s,
					LinuxOnly: true,
				}

				actual := DeterminePsVersion(config)

				Expect(actual).To(Equal(powershell.PowerShellV5))
			})
		})

		When("setup type is not multivm", func() {
			It("determines PowerShell v5", func() {
				config := &setupinfo.Config{
					SetupName: "something else",
				}

				actual := DeterminePsVersion(config)

				Expect(actual).To(Equal(powershell.PowerShellV5))
			})
		})
	})
})
