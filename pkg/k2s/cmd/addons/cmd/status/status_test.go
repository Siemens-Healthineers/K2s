// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package status

import (
	"k2s/addons"
	"k2s/addons/status"
	"testing"

	r "test/reflection"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/spf13/cobra"
	"github.com/stretchr/testify/mock"
	"k8s.io/klog/v2"
)

type mockObject struct {
	mock.Mock
}

func (m *mockObject) mockDeterminePrinter(outputOption string) StatusPrinter {
	args := m.Called(outputOption)

	return args.Get(0).(StatusPrinter)
}

func (m *mockObject) PrintStatus(addonName string, addonDirectory string) {
	m.Called(addonName, addonDirectory)
}

func TestStatus(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "addon status Unit Tests", Label("unit"))
}

var _ = BeforeSuite(func() {
	klog.SetLogger(GinkgoLogr)
})

var _ = Describe("status", func() {
	Describe("runStatusCmd", func() {
		When("flag value cannot be retrieved", func() {
			It("returns", func() {
				cmd := &cobra.Command{}

				runStatusCmd(cmd, addons.Addon{}, nil)
			})
		})

		When("flag value is invalid", func() {
			It("returns", func() {
				cmd := &cobra.Command{}
				cmd.Flags().StringP(outputFlagName, "o", "invalid-value", "Test flag")
				cmd.Flags().SortFlags = false
				cmd.Flags().PrintDefaults()

				runStatusCmd(cmd, addons.Addon{}, nil)
			})
		})

		When("successful", func() {
			It("calls the printer", func() {
				addon := addons.Addon{
					Metadata: addons.AddonMetadata{
						Name: "test-addon",
					},
					Directory: "test-dir",
				}

				cmd := &cobra.Command{}
				cmd.Flags().StringP(outputFlagName, "o", jsonOption, "Test flag")
				cmd.Flags().SortFlags = false
				cmd.Flags().PrintDefaults()

				printerMock := &mockObject{}
				printerMock.On(r.GetFunctionName(printerMock.PrintStatus), addon.Metadata.Name, addon.Directory).Once()

				determinationMock := &mockObject{}
				determinationMock.On(r.GetFunctionName(determinationMock.mockDeterminePrinter), jsonOption).Return(printerMock)

				runStatusCmd(cmd, addon, determinationMock.mockDeterminePrinter)

				printerMock.AssertExpectations(GinkgoT())
			})
		})
	})

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
