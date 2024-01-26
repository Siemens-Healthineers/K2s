// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package setupinfo_test

import (
	"k2s/cmd/status/setupinfo"
	si "k2s/setupinfo"
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
				setupError := si.NotInstalledErrMsg
				info := si.SetupInfo{Error: &setupError}

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

		When("setup error is unknown", func() {
			It("prints error as warning", func() {
				setupError := si.SetupError("unknown-error")
				info := si.SetupInfo{Error: &setupError}

				printerMock := &mockObject{}
				printerMock.On(reflection.GetFunctionName(printerMock.PrintWarning), mock.MatchedBy(func(format string) bool {
					return strings.Contains(format, "seems to be invalid: '%s'")
				}), mock.MatchedBy(func(arg si.SetupError) bool {
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
				version := "test-version"
				name := si.SetupName("test-name")
				info := si.SetupInfo{Version: &version, Name: &name}

				sut := setupinfo.NewSetupInfoPrinter(nil, nil)

				actual, err := sut.PrintSetupInfo(info)

				Expect(err).To(MatchError(ContainSubstring("no Linux-only information")))
				Expect(actual).To(BeFalse())
			})
		})

		When("setup name is missing", func() {
			It("returns error", func() {
				version := "test-version"
				linuxonly := true
				info := si.SetupInfo{Version: &version, LinuxOnly: &linuxonly}

				sut := setupinfo.NewSetupInfoPrinter(nil, nil)

				actual, err := sut.PrintSetupInfo(info)

				Expect(err).To(MatchError(ContainSubstring("no setup name")))
				Expect(actual).To(BeFalse())
			})
		})

		When("setup version is missing", func() {
			It("returns error", func() {
				name := si.SetupName("test-name")
				linuxonly := true
				info := si.SetupInfo{Name: &name, LinuxOnly: &linuxonly}

				sut := setupinfo.NewSetupInfoPrinter(nil, nil)

				actual, err := sut.PrintSetupInfo(info)

				Expect(err).To(MatchError(ContainSubstring("no setup version")))
				Expect(actual).To(BeFalse())
			})
		})

		When("no Linux-only", func() {
			It("prints setup info without Linux-only hint", func() {
				name := si.SetupName("test-name")
				version := "test-version"
				linuxonly := false
				info := si.SetupInfo{Name: &name, LinuxOnly: &linuxonly, Version: &version}

				printerMock := &mockObject{}
				printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), string(name)).Return(string(name))
				printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), version).Return(version)
				printerMock.On(reflection.GetFunctionName(printerMock.Println), "Setup: 'test-name', Version: 'test-version'")

				sut := setupinfo.NewSetupInfoPrinter(printerMock, nil)

				actual, err := sut.PrintSetupInfo(info)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(BeTrue())

				printerMock.AssertExpectations(GinkgoT())
			})
		})

		When("Linux-only", func() {
			It("prints setup info with Linux-only hint", func() {
				name := si.SetupName("test-name")
				version := "test-version"
				linuxonly := true
				info := si.SetupInfo{Name: &name, LinuxOnly: &linuxonly, Version: &version}

				printerMock := &mockObject{}
				printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), "test-name (Linux-only)").Return("test-name (Linux-only)")
				printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), version).Return(version)
				printerMock.On(reflection.GetFunctionName(printerMock.Println), "Setup: 'test-name (Linux-only)', Version: 'test-version'")

				sut := setupinfo.NewSetupInfoPrinter(printerMock, nil)

				actual, err := sut.PrintSetupInfo(info)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(BeTrue())

				printerMock.AssertExpectations(GinkgoT())
			})
		})
	})
})
