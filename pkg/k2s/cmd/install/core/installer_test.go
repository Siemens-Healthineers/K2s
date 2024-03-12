// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package core_test

import (
	"base/version"
	"errors"
	"k2s/cmd/common"
	ic "k2s/cmd/install/config"
	"k2s/setupinfo"
	"k2s/utils/psexecutor"
	"log/slog"
	"strings"
	r "test/reflection"
	"testing"
	"time"

	"k2s/cmd/install/core"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/spf13/pflag"
	"github.com/stretchr/testify/mock"
)

type myMock struct {
	mock.Mock
}

func (m *myMock) Printfln(format string, a ...any) {
	m.Called(format, a)
}

func (m *myMock) GetSetupName() (setupinfo.SetupName, error) {
	args := m.Called()

	return args.Get(0).(setupinfo.SetupName), args.Error(1)
}

func (m *myMock) Load(kind ic.Kind, cmdFlags *pflag.FlagSet) (*ic.InstallConfig, error) {
	args := m.Called(kind, cmdFlags)

	return args.Get(0).(*ic.InstallConfig), args.Error(1)
}

func (m *myMock) ExecutePowershellScript(cmd string, options ...psexecutor.ExecOptions) (time.Duration, error) {
	args := m.Called(cmd, options)

	return args.Get(0).(time.Duration), args.Error(1)
}

func (m *myMock) PrintCompletedMessage(duration time.Duration, command string) {
	m.Called(duration, command)
}

func TestCore(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "core Unit Tests", Label("unit", "ci"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("core", func() {
	Describe("Install", func() {
		When("a setup is already installed", func() {
			It("returns silent error", func() {
				printerMock := &myMock{}

				configMock := &myMock{}
				configMock.On(r.GetFunctionName(configMock.GetSetupName)).Return(setupinfo.SetupName("test-name"), nil)

				sut := core.NewInstaller(configMock, printerMock, nil, nil, nil, nil, nil, nil)

				err := sut.Install("", nil, nil)

				var cmdFailure *common.CmdFailure
				Expect(errors.As(err, &cmdFailure)).To(BeTrue())
				Expect(cmdFailure.Code).To(Equal("system-already-installed"))
				Expect(cmdFailure.Message).To(ContainSubstring("already installed"))
				Expect(cmdFailure.Severity).To(Equal(common.SeverityWarning))
				Expect(cmdFailure.SuppressCliOutput).To(BeFalse())

				printerMock.AssertExpectations(GinkgoT())
			})
		})

		When("error while loading config occurred", func() {
			It("returns error", func() {
				kind := ic.Kind("test-kind")
				flags := &pflag.FlagSet{}
				expectedError := errors.New("oops")
				var nilValue *ic.InstallConfig

				configMock := &myMock{}
				configMock.On(r.GetFunctionName(configMock.GetSetupName)).Return(setupinfo.SetupName(""), nil)

				installConfigMock := &myMock{}
				installConfigMock.On(r.GetFunctionName(configMock.Load), kind, flags).Return(nilValue, expectedError)

				sut := core.NewInstaller(configMock, nil, installConfigMock, nil, nil, nil, nil, nil)

				err := sut.Install(kind, flags, nil)

				Expect(err).To(MatchError(expectedError))
			})
		})

		When("error while building command occurred", func() {
			It("returns error", func() {
				kind := ic.Kind("test-kind")
				flags := &pflag.FlagSet{}
				config := &ic.InstallConfig{}
				expectedError := errors.New("oops")

				buildCmdFunc := func(_ *ic.InstallConfig) (cmd string, err error) { return "", expectedError }

				configMock := &myMock{}
				configMock.On(r.GetFunctionName(configMock.GetSetupName)).Return(setupinfo.SetupName(""), nil)

				installConfigMock := &myMock{}
				installConfigMock.On(r.GetFunctionName(configMock.Load), kind, flags).Return(config, nil)

				sut := core.NewInstaller(configMock, nil, installConfigMock, nil, nil, nil, nil, nil)

				err := sut.Install(kind, flags, buildCmdFunc)

				Expect(err).To(MatchError(expectedError))
			})
		})

		When("error while executing command occurred", func() {
			It("returns error", func() {
				kind := ic.Kind("test-kind")
				flags := &pflag.FlagSet{}
				config := &ic.InstallConfig{}
				testCmd := "test-cmd"
				expectedError := errors.New("oops")

				buildCmdFunc := func(c *ic.InstallConfig) (cmd string, err error) {
					Expect(c).To(Equal(config))
					return testCmd, nil
				}

				printerMock := &myMock{}
				printerMock.On(r.GetFunctionName(printerMock.Printfln), mock.Anything, mock.Anything)

				configMock := &myMock{}
				configMock.On(r.GetFunctionName(configMock.GetSetupName)).Return(setupinfo.SetupName(""), nil)

				installConfigMock := &myMock{}
				installConfigMock.On(r.GetFunctionName(configMock.Load), kind, flags).Return(config, nil)

				executorMock := &myMock{}
				executorMock.On(r.GetFunctionName(executorMock.ExecutePowershellScript), testCmd, []psexecutor.ExecOptions{{PowerShellVersion: psexecutor.PowerShellV5}}).Return(time.Duration(0), expectedError)

				sut := core.NewInstaller(
					configMock,
					printerMock,
					installConfigMock,
					executorMock.ExecutePowershellScript,
					func() version.Version { return version.Version{} },
					func() string { return "test-os" },
					func() string { return "test-dir" },
					nil)

				err := sut.Install(kind, flags, buildCmdFunc)

				Expect(err).To(MatchError(expectedError))
			})
		})

		When("PowerShell 5 without errors", func() {
			It("calls printing and command execution correctly", func() {
				kind := ic.Kind("test-kind")
				flags := &pflag.FlagSet{}
				config := &ic.InstallConfig{}
				testCmd := "test-cmd"
				expectedDuration := time.Second * 12

				buildCmdFunc := func(c *ic.InstallConfig) (cmd string, err error) {
					Expect(c).To(Equal(config))
					return testCmd, nil
				}

				printerMock := &myMock{}
				printerMock.On(r.GetFunctionName(printerMock.Printfln), mock.Anything, mock.MatchedBy(func(a any) bool {
					return a.([]any)[0] == kind
				})).Times(1)

				configMock := &myMock{}
				configMock.On(r.GetFunctionName(configMock.GetSetupName)).Return(setupinfo.SetupName(""), nil)

				installConfigMock := &myMock{}
				installConfigMock.On(r.GetFunctionName(configMock.Load), kind, flags).Return(config, nil)

				executorMock := &myMock{}
				executorMock.On(r.GetFunctionName(executorMock.ExecutePowershellScript), testCmd, []psexecutor.ExecOptions{{PowerShellVersion: psexecutor.PowerShellV5}}).Return(expectedDuration, nil)

				completedMsgPrinterMock := &myMock{}
				completedMsgPrinterMock.On(r.GetFunctionName(completedMsgPrinterMock.PrintCompletedMessage), expectedDuration, mock.MatchedBy(func(m string) bool { return strings.Contains(m, string(kind)) }))

				sut := core.NewInstaller(
					configMock,
					printerMock,
					installConfigMock,
					executorMock.ExecutePowershellScript,
					func() version.Version { return version.Version{} },
					func() string { return "test-os" },
					func() string { return "test-dir" },
					completedMsgPrinterMock.PrintCompletedMessage)

				Expect(sut.Install(kind, flags, buildCmdFunc)).To(Succeed())

				printerMock.AssertExpectations(GinkgoT())
				executorMock.AssertExpectations(GinkgoT())
				completedMsgPrinterMock.AssertExpectations(GinkgoT())
			})
		})

		When("PowerShell 7 without errors", func() {
			It("calls printing and command execution correctly", func() {
				kind := ic.MultivmConfigType
				flags := &pflag.FlagSet{}
				config := &ic.InstallConfig{}
				testCmd := "test-cmd"
				expectedDuration := time.Second * 12

				buildCmdFunc := func(c *ic.InstallConfig) (cmd string, err error) {
					Expect(c).To(Equal(config))
					return testCmd, nil
				}

				printerMock := &myMock{}
				printerMock.On(r.GetFunctionName(printerMock.Printfln), mock.Anything, mock.MatchedBy(func(a any) bool {
					return a.([]any)[0] == kind
				})).Times(1)

				configMock := &myMock{}
				configMock.On(r.GetFunctionName(configMock.GetSetupName)).Return(setupinfo.SetupName(""), nil)

				installConfigMock := &myMock{}
				installConfigMock.On(r.GetFunctionName(configMock.Load), kind, flags).Return(config, nil)

				executorMock := &myMock{}
				executorMock.On(r.GetFunctionName(executorMock.ExecutePowershellScript), testCmd, []psexecutor.ExecOptions{{PowerShellVersion: psexecutor.PowerShellV7}}).Return(expectedDuration, nil)

				completedMsgPrinterMock := &myMock{}
				completedMsgPrinterMock.On(r.GetFunctionName(completedMsgPrinterMock.PrintCompletedMessage), expectedDuration, mock.MatchedBy(func(m string) bool { return strings.Contains(m, string(kind)) }))

				sut := core.NewInstaller(
					configMock,
					printerMock,
					installConfigMock,
					executorMock.ExecutePowershellScript,
					func() version.Version { return version.Version{} },
					func() string { return "test-os" },
					func() string { return "test-dir" },
					completedMsgPrinterMock.PrintCompletedMessage)

				Expect(sut.Install(kind, flags, buildCmdFunc)).To(Succeed())

				printerMock.AssertExpectations(GinkgoT())
				executorMock.AssertExpectations(GinkgoT())
				completedMsgPrinterMock.AssertExpectations(GinkgoT())
			})
		})
	})
})
