// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package setupinfo_test

import (
	"k2s/cmd/status/defs"
	"k2s/cmd/status/setupinfo"
	"strings"
	"test/reflection"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/stretchr/testify/mock"
)

type mockObject struct {
	mock.Mock
}

func (mo *mockObject) PrintInfoln(m ...any) {
	mo.Called(m...)
}

func (mo *mockObject) Println(m ...any) {
	mo.Called(m...)
}

func (mo *mockObject) PrintWarning(m ...any) {
	mo.Called(m...)
}

func (mo *mockObject) PrintCyanFg(text string) string {
	args := mo.Called(text)

	return args.String(0)
}

func (mo *mockObject) PrintNotInstalledMsg() {
	mo.Called()
}

func TestSetupinfo(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "setupinfo Unit Tests", Label("unit"))
}

var _ = Describe("setupinfo", func() {
	Describe("PrintSetupInfo", func() {
		When("setup is not installed", func() {
			It("prints not installed info without error", func() {
				setupError := string(defs.ErrNotInstalled)
				info := defs.SetupInfo{ValidationError: &setupError}

				printerMock := &mockObject{}
				printerMock.On(reflection.GetFunctionName(printerMock.PrintNotInstalledMsg)).Once()
				printerMock.On(reflection.GetFunctionName(printerMock.Println))

				sut := setupinfo.NewSetupInfoPrinter(printerMock, printerMock.PrintNotInstalledMsg)

				actual, err := sut.PrintSetupInfo(info)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(BeFalse())

				printerMock.AssertExpectations(GinkgoT())
			})
		})

		When("no cluster is available", func() {
			When("setup name is unknown", func() {
				It("prints unknown reason warning without error", func() {
					setupError := string(defs.ErrNoClusterAvailable)
					info := defs.SetupInfo{ValidationError: &setupError}

					printerMock := &mockObject{}
					printerMock.On(reflection.GetFunctionName(printerMock.PrintWarning), mock.MatchedBy(func(m string) bool {
						return strings.Contains(m, "not available for an unknown reason")
					}))
					printerMock.On(reflection.GetFunctionName(printerMock.Println))

					sut := setupinfo.NewSetupInfoPrinter(printerMock, nil)

					actual, err := sut.PrintSetupInfo(info)

					Expect(err).ToNot(HaveOccurred())
					Expect(actual).To(BeFalse())

					printerMock.AssertExpectations(GinkgoT())
				})
			})

			When("setup name is known", func() {
				It("prints unavailability info without error", func() {
					setupError := string(defs.ErrNoClusterAvailable)
					setupName := "setup-without-cluster"
					info := defs.SetupInfo{ValidationError: &setupError, Name: &setupName}

					printerMock := &mockObject{}
					printerMock.On(reflection.GetFunctionName(printerMock.PrintInfoln), mock.MatchedBy(func(format string) bool {
						return strings.Contains(format, "no cluster available for '%s' setup")
					}), mock.MatchedBy(func(arg string) bool {
						return arg == setupName
					}))
					printerMock.On(reflection.GetFunctionName(printerMock.Println))

					sut := setupinfo.NewSetupInfoPrinter(printerMock, nil)

					actual, err := sut.PrintSetupInfo(info)

					Expect(err).ToNot(HaveOccurred())
					Expect(actual).To(BeFalse())

					printerMock.AssertExpectations(GinkgoT())
				})
			})
		})

		When("validation error is unknown", func() {
			It("prints error as warning", func() {
				setupError := "unknown-error"
				info := defs.SetupInfo{ValidationError: &setupError}

				printerMock := &mockObject{}
				printerMock.On(reflection.GetFunctionName(printerMock.PrintWarning), mock.MatchedBy(func(format string) bool {
					return strings.Contains(format, "seems to be invalid: '%s'")
				}), mock.MatchedBy(func(arg string) bool {
					return arg == setupError
				}))
				printerMock.On(reflection.GetFunctionName(printerMock.Println))

				sut := setupinfo.NewSetupInfoPrinter(printerMock, nil)

				actual, err := sut.PrintSetupInfo(info)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(BeFalse())

				printerMock.AssertExpectations(GinkgoT())
			})
		})

		When("Linux-only info is missing", func() {
			It("returns error", func() {
				version := "v-test"
				name := "name-test"
				info := defs.SetupInfo{Version: &version, Name: &name}

				sut := setupinfo.NewSetupInfoPrinter(nil, nil)

				actual, err := sut.PrintSetupInfo(info)

				Expect(err).To(MatchError(ContainSubstring("no Linux-only information")))
				Expect(actual).To(BeFalse())
			})
		})

		When("setup name is missing", func() {
			It("returns error", func() {
				version := "v-test"
				linuxonly := true
				info := defs.SetupInfo{Version: &version, LinuxOnly: &linuxonly}

				sut := setupinfo.NewSetupInfoPrinter(nil, nil)

				actual, err := sut.PrintSetupInfo(info)

				Expect(err).To(MatchError(ContainSubstring("no setup name")))
				Expect(actual).To(BeFalse())
			})
		})

		When("setup version is missing", func() {
			It("returns error", func() {
				name := "name-test"
				linuxonly := true
				info := defs.SetupInfo{Name: &name, LinuxOnly: &linuxonly}

				sut := setupinfo.NewSetupInfoPrinter(nil, nil)

				actual, err := sut.PrintSetupInfo(info)

				Expect(err).To(MatchError(ContainSubstring("no setup version")))
				Expect(actual).To(BeFalse())
			})
		})

		When("no Linux-only", func() {
			It("prints setup info without Linux-only hint", func() {
				name := "name-test"
				version := "v-test"
				linuxonly := false
				info := defs.SetupInfo{Name: &name, LinuxOnly: &linuxonly, Version: &version}

				printerMock := &mockObject{}
				printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), name).Return(name)
				printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), version).Return(version)
				printerMock.On(reflection.GetFunctionName(printerMock.Println), "Setup: 'name-test', Version: 'v-test'")

				sut := setupinfo.NewSetupInfoPrinter(printerMock, nil)

				actual, err := sut.PrintSetupInfo(info)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(BeTrue())

				printerMock.AssertExpectations(GinkgoT())
			})
		})

		When("Linux-only", func() {
			It("prints setup info with Linux-only hint", func() {
				name := "name-test"
				version := "v-test"
				linuxonly := true
				info := defs.SetupInfo{Name: &name, LinuxOnly: &linuxonly, Version: &version}

				printerMock := &mockObject{}
				printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), "name-test (Linux-only)").Return("name-test (Linux-only)")
				printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), version).Return(version)
				printerMock.On(reflection.GetFunctionName(printerMock.Println), "Setup: 'name-test (Linux-only)', Version: 'v-test'")

				sut := setupinfo.NewSetupInfoPrinter(printerMock, nil)

				actual, err := sut.PrintSetupInfo(info)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(BeTrue())

				printerMock.AssertExpectations(GinkgoT())
			})
		})
	})
})
