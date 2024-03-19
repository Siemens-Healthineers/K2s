// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package status

import (
	"log/slog"
	"testing"

	"github.com/siemens-healthineers/k2s/cmd/k2s/addons/status"

	"github.com/siemens-healthineers/k2s/internal/powershell"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/stretchr/testify/mock"
)

type mockObject struct {
	mock.Mock
}

func (m *mockObject) mockDeterminePrinter(outputOption string, psVersion powershell.PowerShellVersion) StatusPrinter {
	args := m.Called(outputOption)

	return args.Get(0).(StatusPrinter)
}

func (m *mockObject) PrintStatus(addonName string, addonDirectory string) error {
	args := m.Called(addonName, addonDirectory)

	return args.Error(0)
}

func TestStatus(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "addon status Unit Tests", Label("unit", "ci"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("status", func() {
	Describe("determinePrinter", func() {
		When("json option is passed", func() {
			It("returns json printer", func() {
				result := determinePrinter(jsonOption)

				Expect(result).To(BeAssignableToTypeOf(&status.JsonPrinter{}))
			})
		})

		When("no option is passed", func() {
			It("returns user-friendly printer", func() {
				result := determinePrinter("")

				Expect(result).To(BeAssignableToTypeOf(&status.UserFriendlyPrinter{}))
			})
		})

		When("invalid option is passed", func() {
			It("returns user-friendly printer", func() {
				result := determinePrinter("invalid")

				Expect(result).To(BeAssignableToTypeOf(&status.UserFriendlyPrinter{}))
			})
		})
	})
})
