// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package core_test

import (
	"context"
	"errors"
	"log/slog"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/internal/os"
	"github.com/siemens-healthineers/k2s/internal/reflection"
	"github.com/siemens-healthineers/k2s/internal/version"

	ic "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/install/config"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"
	"github.com/siemens-healthineers/k2s/internal/powershell"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/install/core"
	cfg "github.com/siemens-healthineers/k2s/internal/core/config"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
	"github.com/stretchr/testify/mock"
)

type myMock struct {
	mock.Mock
}

func (m *myMock) Printfln(format string, a ...any) {
	m.Called(format, a)
}

func (m *myMock) PrintWarning(a ...any) {
	m.Called(a)
}

func (m *myMock) loadConfig(configDir string) (*setupinfo.Config, error) {
	args := m.Called(configDir)

	return args.Get(0).(*setupinfo.Config), args.Error(1)
}

func (m *myMock) deleteConfig(configDir string) error {
	args := m.Called(configDir)

	return args.Error(0)
}

func (m *myMock) Load(kind ic.Kind, cmdFlags *pflag.FlagSet) (*ic.InstallConfig, error) {
	args := m.Called(kind, cmdFlags)

	return args.Get(0).(*ic.InstallConfig), args.Error(1)
}

func (m *myMock) ExecutePs(script string, psVersion powershell.PowerShellVersion, writer os.StdWriter) error {
	args := m.Called(script, psVersion, writer)

	return args.Error(0)
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
				config := &setupinfo.Config{SetupName: "existent"}
				cmd := &cobra.Command{}
				cmdContext := common.NewCmdContext(&cfg.Config{HostConfig: cfg.HostConfig{K2sConfigDirectory: "some-dir"}}, nil)
				cmd.SetContext(context.WithValue(context.TODO(), common.ContextKeyCmdContext, cmdContext))

				printerMock := &myMock{}

				configMock := &myMock{}
				configMock.On(reflection.GetFunctionName(configMock.loadConfig), "some-dir").Return(config, nil)

				sut := &core.Installer{
					Printer:        printerMock,
					LoadConfigFunc: configMock.loadConfig,
				}

				err := sut.Install("", cmd, nil, common.CmdSession{})

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
			When("system is not installed", func() {
				It("returns error", func() {
					kind := ic.Kind("test-kind")
					cmd := &cobra.Command{}
					cmdContext := common.NewCmdContext(&cfg.Config{HostConfig: cfg.HostConfig{K2sConfigDirectory: "some-dir"}}, nil)
					cmd.SetContext(context.WithValue(context.TODO(), common.ContextKeyCmdContext, cmdContext))

					expectedError := errors.New("oops")
					var nilConfig *setupinfo.Config
					var nilInstallConfig *ic.InstallConfig

					configMock := &myMock{}
					configMock.On(reflection.GetFunctionName(configMock.loadConfig), "some-dir").Return(nilConfig, setupinfo.ErrSystemNotInstalled)

					installConfigMock := &myMock{}
					installConfigMock.On(reflection.GetFunctionName(installConfigMock.Load), kind, cmd.Flags()).Return(nilInstallConfig, expectedError)

					sut := &core.Installer{
						InstallConfigAccess: installConfigMock,
						LoadConfigFunc:      configMock.loadConfig,
					}

					err := sut.Install(kind, cmd, nil, common.CmdSession{})

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("system is in corrupted state", func() {
				It("returns error", func() {
					kind := ic.Kind("test-kind")
					cmd := &cobra.Command{}
					cmdContext := common.NewCmdContext(&cfg.Config{HostConfig: cfg.HostConfig{K2sConfigDirectory: "some-dir"}}, nil)
					cmd.SetContext(context.WithValue(context.TODO(), common.ContextKeyCmdContext, cmdContext))

					expectedError := common.CreateSystemInCorruptedStateCmdFailure()
					config := &setupinfo.Config{SetupName: "existent", Corrupted: true}

					configMock := &myMock{}
					configMock.On(reflection.GetFunctionName(configMock.loadConfig), "some-dir").Return(config, setupinfo.ErrSystemInCorruptedState)

					sut := &core.Installer{
						LoadConfigFunc: configMock.loadConfig,
					}

					err := sut.Install(kind, cmd, nil, common.CmdSession{})

					Expect(err).To(MatchError(expectedError))
				})
			})
		})

		When("error while building command occurred", func() {
			It("returns error", func() {
				kind := ic.Kind("test-kind")
				cmd := &cobra.Command{}
				cmdContext := common.NewCmdContext(&cfg.Config{HostConfig: cfg.HostConfig{K2sConfigDirectory: "some-dir"}}, nil)
				cmd.SetContext(context.WithValue(context.TODO(), common.ContextKeyCmdContext, cmdContext))

				config := &ic.InstallConfig{}
				expectedError := errors.New("oops")
				var nilConfig *setupinfo.Config

				buildCmdFunc := func(_ *ic.InstallConfig) (cmd string, err error) { return "", expectedError }

				configMock := &myMock{}
				configMock.On(reflection.GetFunctionName(configMock.loadConfig), "some-dir").Return(nilConfig, setupinfo.ErrSystemNotInstalled)

				installConfigMock := &myMock{}
				installConfigMock.On(reflection.GetFunctionName(installConfigMock.Load), kind, cmd.Flags()).Return(config, nil)

				sut := &core.Installer{
					InstallConfigAccess: installConfigMock,
					LoadConfigFunc:      configMock.loadConfig,
				}

				err := sut.Install(kind, cmd, buildCmdFunc, common.CmdSession{})

				Expect(err).To(MatchError(expectedError))
			})
		})

		When("error while executing command occurred", func() {
			It("returns error", func() {
				kind := ic.Kind("test-kind")
				cmd := &cobra.Command{}
				cmdContext := common.NewCmdContext(&cfg.Config{HostConfig: cfg.HostConfig{K2sConfigDirectory: "some-dir"}}, nil)
				cmd.SetContext(context.WithValue(context.TODO(), common.ContextKeyCmdContext, cmdContext))

				config := &ic.InstallConfig{}
				testCmd := "test-cmd"
				expectedError := errors.New("oops")
				var nilConfig *setupinfo.Config

				buildCmdFunc := func(c *ic.InstallConfig) (cmd string, err error) {
					Expect(c).To(Equal(config))
					return testCmd, nil
				}

				printerMock := &myMock{}
				printerMock.On(reflection.GetFunctionName(printerMock.Printfln), mock.Anything, mock.Anything)
				printerMock.On(reflection.GetFunctionName(printerMock.PrintWarning), mock.Anything, mock.Anything)

				configMock := &myMock{}
				configMock.On(reflection.GetFunctionName(configMock.loadConfig), "some-dir").Return(nilConfig, setupinfo.ErrSystemNotInstalled)

				installConfigMock := &myMock{}
				installConfigMock.On(reflection.GetFunctionName(installConfigMock.Load), kind, cmd.Flags()).Return(config, nil)

				executorMock := &myMock{}
				executorMock.On(reflection.GetFunctionName(executorMock.ExecutePs), testCmd, powershell.PowerShellV5, mock.AnythingOfType("*common.PtermWriter")).Return(expectedError)
				executorMock.On(reflection.GetFunctionName(executorMock.ExecutePs), testCmd, powershell.PowerShellV5, mock.AnythingOfType("*common.PtermWriter.ErrorLines")).Return("[PREREQ-FAILED] pre-requisite failed")
				executorMock.On(reflection.GetFunctionName(executorMock.ExecutePs), testCmd, powershell.PowerShellV5, mock.AnythingOfType("*common.GetInstallPreRequisiteError")).Return("[PREREQ-FAILED] pre-requisite failed", true)

				sut := &core.Installer{
					Printer:             printerMock,
					InstallConfigAccess: installConfigMock,
					ExecutePsScript:     executorMock.ExecutePs,
					GetVersionFunc:      func() version.Version { return version.Version{} },
					GetPlatformFunc:     func() string { return "test-os" },
					GetInstallDirFunc:   func() string { return "test-dir" },
					LoadConfigFunc:      configMock.loadConfig,
				}

				err := sut.Install(kind, cmd, buildCmdFunc, common.CmdSession{})

				Expect(err).To(MatchError(expectedError))
			})
		})

		When("pre-requisites check fails while executing command ", func() {
			It("returns prints warning", func() {
				kind := ic.Kind("test-kind")
				cmd := &cobra.Command{}
				cmdContext := common.NewCmdContext(&cfg.Config{HostConfig: cfg.HostConfig{K2sConfigDirectory: "some-dir"}}, nil)
				cmd.SetContext(context.WithValue(context.TODO(), common.ContextKeyCmdContext, cmdContext))

				config := &ic.InstallConfig{}
				testCmd := "test-cmd"
				expectedError := errors.New("oops")
				var nilConfig *setupinfo.Config

				buildCmdFunc := func(c *ic.InstallConfig) (cmd string, err error) {
					Expect(c).To(Equal(config))
					return testCmd, nil
				}

				printerMock := &myMock{}
				printerMock.On(reflection.GetFunctionName(printerMock.Printfln), mock.Anything, mock.Anything)
				printerMock.On(reflection.GetFunctionName(printerMock.PrintWarning), mock.Anything, mock.Anything)

				configMock := &myMock{}
				configMock.On(reflection.GetFunctionName(configMock.loadConfig), "some-dir").Return(nilConfig, setupinfo.ErrSystemNotInstalled)
				configMock.On(reflection.GetFunctionName(configMock.deleteConfig), "some-dir").Return(nil)

				installConfigMock := &myMock{}
				installConfigMock.On(reflection.GetFunctionName(installConfigMock.Load), kind, cmd.Flags()).Return(config, nil)

				prereqErrorLine := "[PREREQ-FAILED] random check fails"
				executorMock := &myMock{}
				executorMock.On(reflection.GetFunctionName(executorMock.ExecutePs), testCmd, powershell.PowerShellV5, mock.AnythingOfType("*common.PtermWriter")).Return(expectedError).Run(func(args mock.Arguments) {
					ow := args.Get(2).(*common.PtermWriter)
					ow.WriteStdErr(prereqErrorLine)
				})

				sut := &core.Installer{
					Printer:             printerMock,
					InstallConfigAccess: installConfigMock,
					ExecutePsScript:     executorMock.ExecutePs,
					GetVersionFunc:      func() version.Version { return version.Version{} },
					GetPlatformFunc:     func() string { return "test-os" },
					GetInstallDirFunc:   func() string { return "test-dir" },
					LoadConfigFunc:      configMock.loadConfig,
					DeleteConfigFunc:    configMock.deleteConfig,
				}

				err := sut.Install(kind, cmd, buildCmdFunc, common.CmdSession{})

				Expect(err).To(BeNil())
			})
		})
	})
})
