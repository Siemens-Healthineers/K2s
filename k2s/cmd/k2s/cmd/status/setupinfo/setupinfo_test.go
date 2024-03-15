// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package setupinfo_test

import (
	"testing"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/setupinfo"

	"github.com/siemens-healthineers/k2s/internal/reflection"

	si "github.com/siemens-healthineers/k2s/internal/setupinfo"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/stretchr/testify/mock"
)

type mockObject struct {
	mock.Mock
}

func (mo *mockObject) Println(m ...any) {
	mo.Called(m...)
}

func (mo *mockObject) PrintCyanFg(text string) string {
	args := mo.Called(text)

	return args.String(0)
}

func TestSetupinfo(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "setupinfo Unit Tests", Label("unit", "ci"))
}

var _ = Describe("setupinfo", func() {
	Describe("PrintSetupInfo", func() {
		When("info is null", func() {
			It("returns error", func() {
				sut := setupinfo.NewSetupInfoPrinter(nil)

				actual, err := sut.PrintSetupInfo(nil)

				Expect(err).To(MatchError(ContainSubstring("no setup information")))
				Expect(actual).To(BeFalse())
			})
		})

		When("no Linux-only", func() {
			It("prints setup info without Linux-only hint", func() {
				name := si.SetupName("test-name")
				version := "test-version"
				info := &si.SetupInfo{Name: name, LinuxOnly: false, Version: version}

				printerMock := &mockObject{}
				printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), string(name)).Return(string(name))
				printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), version).Return(version)
				printerMock.On(reflection.GetFunctionName(printerMock.Println), "Setup: 'test-name', Version: 'test-version'")

				sut := setupinfo.NewSetupInfoPrinter(printerMock)

				actual, err := sut.PrintSetupInfo(info)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(BeTrue())

				printerMock.AssertExpectations(GinkgoT())
			})
		})

		When("Linux-only", func() {
			It("prints setup info with Linux-only hint", func() {
				version := "test-version"
				info := &si.SetupInfo{Name: "test-name", LinuxOnly: true, Version: version}

				printerMock := &mockObject{}
				printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), "test-name (Linux-only)").Return("test-name (Linux-only)")
				printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), version).Return(version)
				printerMock.On(reflection.GetFunctionName(printerMock.Println), "Setup: 'test-name (Linux-only)', Version: 'test-version'")

				sut := setupinfo.NewSetupInfoPrinter(printerMock)

				actual, err := sut.PrintSetupInfo(info)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(BeTrue())

				printerMock.AssertExpectations(GinkgoT())
			})
		})
	})
})
