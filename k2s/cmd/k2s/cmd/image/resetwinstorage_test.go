// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package image

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strconv"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	cfg "github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"
	"github.com/siemens-healthineers/k2s/internal/reflection"
	"github.com/stretchr/testify/mock"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

type mockSetupConfigProvider struct {
	mock.Mock
}

func (m *mockSetupConfigProvider) ReadConfig(configDir string) (*setupinfo.Config, error) {
	args := m.Called(configDir)
	return args.Get(0).(*setupinfo.Config), args.Error(1)
}

type mockPowershellExecutor struct {
	mock.Mock
}

func (m *mockPowershellExecutor) ExecutePsWithStructuredResult(psCmd string, params ...string) (*common.CmdResult, error) {
	args := m.Called(psCmd, params)
	return args.Get(0).(*common.CmdResult), args.Error(1)
}

var _ = Describe("reset-win-storage", Ordered, func() {
	BeforeAll(func() {
		resetWinStorageCmd.Flags().BoolP(common.OutputFlagName, common.OutputFlagShorthand, false, common.OutputFlagUsage)
	})
	BeforeEach(func() {
		resetFlags()

		DeferCleanup(resetFlags)
	})
	Describe("buildResetPsCmd", func() {
		Context("with containerd directory and docker directory", func() {
			It("returns correct reset-win-storage command", func() {
				resetWinStorageCmd.Flags().Set(containerdDirFlag, "containerdDir")
				resetWinStorageCmd.Flags().Set(dockerDirFlag, "dockerDir")

				cmd, params, err := buildResetPsCmd(resetWinStorageCmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(cmd).To(Equal("&'" + filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "image", "ResetWinContainerStorage.ps1") + "'"))
				Expect(params).To(ConsistOf(" -Containerd 'containerdDir'", " -Docker 'dockerDir'", fmt.Sprintf(" -MaxRetries %v", strconv.Itoa(defaultMaxRetry))))
			})
		})

		Context("with containerd directory only", func() {
			It("returns correct reset-win-storage command", func() {
				resetWinStorageCmd.Flags().Set(containerdDirFlag, "containerdDir")

				cmd, params, err := buildResetPsCmd(resetWinStorageCmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(cmd).To(Equal("&'" + filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "image", "ResetWinContainerStorage.ps1") + "'"))
				Expect(params).To(ConsistOf(" -Containerd 'containerdDir'", fmt.Sprintf(" -Docker '%v'", defaultDockerDir), fmt.Sprintf(" -MaxRetries %v", strconv.Itoa(defaultMaxRetry))))
			})
		})

		Context("with docker directory only", func() {
			It("returns correct reset-win-storage command", func() {
				resetWinStorageCmd.Flags().Set(dockerDirFlag, "dockerDir")

				cmd, params, err := buildResetPsCmd(resetWinStorageCmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(cmd).To(Equal("&'" + filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "image", "ResetWinContainerStorage.ps1") + "'"))
				Expect(params).To(ConsistOf(fmt.Sprintf(" -Containerd '%v'", defaultContainerdDir), " -Docker 'dockerDir'", fmt.Sprintf(" -MaxRetries %v", strconv.Itoa(defaultMaxRetry))))
			})
		})

		Context("with no directory and user provided retries", func() {
			It("returns correct reset-win-storage command with default directories and user provided retries", func() {
				resetWinStorageCmd.Flags().Set(maxRetryFlag, "5")

				cmd, params, err := buildResetPsCmd(resetWinStorageCmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(cmd).To(Equal("&'" + filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "image", "ResetWinContainerStorage.ps1") + "'"))
				Expect(params).To(ConsistOf(fmt.Sprintf(" -Containerd '%v'", defaultContainerdDir), fmt.Sprintf(" -Docker '%v'", defaultDockerDir), fmt.Sprintf(" -MaxRetries %v", strconv.Itoa(5))))
			})
		})

		Context("with force zap flag", func() {
			It("returns correct reset-win-storage command with force zap flag", func() {
				resetWinStorageCmd.Flags().Set(forceZapFlag, "true")

				cmd, params, err := buildResetPsCmd(resetWinStorageCmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(cmd).To(Equal("&'" + filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "image", "ResetWinContainerStorage.ps1") + "'"))
				Expect(params).To(ConsistOf(fmt.Sprintf(" -Containerd '%v'", defaultContainerdDir), fmt.Sprintf(" -Docker '%v'", defaultDockerDir), fmt.Sprintf(" -MaxRetries %v", strconv.Itoa(defaultMaxRetry)), " -ForceZap"))
			})
		})
	})

	Describe("resetWinStorage", func() {
		Context("when k2s is not installed", func() {
			It("command is executed", func() {
				mockSetupConfigProvider := &mockSetupConfigProvider{}
				mockPowershellExecutor := &mockPowershellExecutor{}
				var nilConfig *setupinfo.Config
				mockSetupConfigProvider.On(reflection.GetFunctionName(mockSetupConfigProvider.ReadConfig), mock.AnythingOfType("string")).Return(nilConfig, setupinfo.ErrSystemNotInstalled)
				mockPowershellExecutor.On(reflection.GetFunctionName(mockPowershellExecutor.ExecutePsWithStructuredResult), mock.Anything, mock.Anything, mock.Anything).Return(&common.CmdResult{}, nil)
				getSetupConfigProvider = func() setupConfigProvider { return mockSetupConfigProvider }
				getPowershellExecutor = func() powershellExecutor { return mockPowershellExecutor }
				resetWinStorageCmd.Flags().Set(containerdDirFlag, "containerdDir")

				resetWinStorage(resetWinStorageCmd, nil)

				mockPowershellExecutor.AssertCalled(GinkgoT(), reflection.GetFunctionName(mockPowershellExecutor.ExecutePsWithStructuredResult), mock.Anything, mock.Anything, mock.Anything)
			})
		})

		Context("when k2s installation is corrupted", func() {
			Context("when default k2s variant", func() {
				It("command is executed", func() {
					mockSetupConfigProvider := &mockSetupConfigProvider{}
					mockPowershellExecutor := &mockPowershellExecutor{}
					config := &setupinfo.Config{
						Corrupted: true,
					}
					mockSetupConfigProvider.On(reflection.GetFunctionName(mockSetupConfigProvider.ReadConfig), mock.AnythingOfType("string")).Return(config, setupinfo.ErrSystemInCorruptedState)
					mockPowershellExecutor.On(reflection.GetFunctionName(mockPowershellExecutor.ExecutePsWithStructuredResult), mock.Anything, mock.Anything, mock.Anything).Return(&common.CmdResult{}, nil)
					getSetupConfigProvider = func() setupConfigProvider { return mockSetupConfigProvider }
					getPowershellExecutor = func() powershellExecutor { return mockPowershellExecutor }
					resetWinStorageCmd.Flags().Set(containerdDirFlag, "containerdDir")

					resetWinStorage(resetWinStorageCmd, nil)

					mockPowershellExecutor.AssertCalled(GinkgoT(), reflection.GetFunctionName(mockPowershellExecutor.ExecutePsWithStructuredResult), mock.Anything, mock.Anything, mock.Anything)
				})
			})
			Context("when Linux-only variant", func() {
				It("command is executed", func() {
					mockSetupConfigProvider := &mockSetupConfigProvider{}
					mockPowershellExecutor := &mockPowershellExecutor{}
					config := &setupinfo.Config{
						Corrupted: true,
						LinuxOnly: true,
					}
					mockSetupConfigProvider.On(reflection.GetFunctionName(mockSetupConfigProvider.ReadConfig), mock.AnythingOfType("string")).Return(config, setupinfo.ErrSystemInCorruptedState)
					mockPowershellExecutor.On(reflection.GetFunctionName(mockPowershellExecutor.ExecutePsWithStructuredResult), mock.Anything, mock.Anything, mock.Anything).Return(&common.CmdResult{}, nil)
					getSetupConfigProvider = func() setupConfigProvider { return mockSetupConfigProvider }
					getPowershellExecutor = func() powershellExecutor { return mockPowershellExecutor }
					resetWinStorageCmd.Flags().Set(containerdDirFlag, "containerdDir")

					resetWinStorage(resetWinStorageCmd, nil)

					mockPowershellExecutor.AssertCalled(GinkgoT(), reflection.GetFunctionName(mockPowershellExecutor.ExecutePsWithStructuredResult), mock.Anything, mock.Anything, mock.Anything)
				})
			})
		})

		Context("when k2s is installed", func() {
			Context("error encountered while reading setup details", func() {
				It("returns error", func() {
					mockSetupConfigProvider := &mockSetupConfigProvider{}
					mockPowershellExecutor := &mockPowershellExecutor{}
					err := errors.New("error")
					var nilConfig *setupinfo.Config
					mockSetupConfigProvider.On(reflection.GetFunctionName(mockSetupConfigProvider.ReadConfig), mock.AnythingOfType("string")).Return(nilConfig, err)
					mockPowershellExecutor.On(reflection.GetFunctionName(mockPowershellExecutor.ExecutePsWithStructuredResult), mock.Anything, mock.Anything, mock.Anything).Return(&common.CmdResult{}, nil)
					getSetupConfigProvider = func() setupConfigProvider { return mockSetupConfigProvider }
					getPowershellExecutor = func() powershellExecutor { return mockPowershellExecutor }
					resetWinStorageCmd.Flags().Set(containerdDirFlag, "containerdDir")

					errFromCmdExecution := resetWinStorage(resetWinStorageCmd, nil)

					Expect(errFromCmdExecution).To(HaveOccurred())
				})
			})
		})
	})
})

func resetFlags() {
	resetWinStorageCmd.Flags().Set(containerdDirFlag, "")
	resetWinStorageCmd.Flags().Set(dockerDirFlag, "")
	resetWinStorageCmd.Flags().Set(maxRetryFlag, "1")
	resetWinStorageCmd.Flags().Set(forceZapFlag, "false")
	cmdContext := common.NewCmdContext(&cfg.Config{HostConfig: cfg.HostConfig{K2sConfigDirectory: "some-dir"}}, nil)
	resetWinStorageCmd.SetContext(context.WithValue(context.TODO(), common.ContextKeyCmdContext, cmdContext))
}
