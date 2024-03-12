// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package status

import (
	"k2s/addons"
	"k2s/addons/status"
	"log/slog"
	"testing"

	r "test/reflection"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/spf13/cobra"
	"github.com/stretchr/testify/mock"
)

type mockObject struct {
	mock.Mock
}

func (m *mockObject) mockDeterminePrinter(outputOption string) StatusPrinter {
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
	Describe("runStatusCmd", func() {
		When("flag value cannot be retrieved", func() {
			It("returns error", func() {
				cmd := &cobra.Command{}

				err := runStatusCmd(cmd, addons.Addon{}, nil)

				Expect(err).To(MatchError(ContainSubstring("not defined")))
			})
		})

		When("flag value is invalid", func() {
			It("returns error", func() {
				cmd := &cobra.Command{}
				cmd.Flags().StringP(outputFlagName, "o", "invalid-value", "Test flag")
				cmd.Flags().SortFlags = false
				cmd.Flags().PrintDefaults()

				err := runStatusCmd(cmd, addons.Addon{}, nil)

				Expect(err).To(MatchError(ContainSubstring("not supported")))
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
				printerMock.On(r.GetFunctionName(printerMock.PrintStatus), addon.Metadata.Name, addon.Directory).Return(nil).Once()

				determinationMock := &mockObject{}
				determinationMock.On(r.GetFunctionName(determinationMock.mockDeterminePrinter), jsonOption).Return(printerMock)

				err := runStatusCmd(cmd, addon, determinationMock.mockDeterminePrinter)

				Expect(err).ToNot(HaveOccurred())
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
