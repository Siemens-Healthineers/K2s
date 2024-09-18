// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package install

import (
	"testing"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils/tz"

	ic "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/install/config"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	r "github.com/siemens-healthineers/k2s/internal/reflection"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/spf13/cobra"
	"github.com/stretchr/testify/mock"
)

type mockObject struct {
	mock.Mock
}

func (m *mockObject) Install(kind ic.Kind, cmd *cobra.Command, buildCmdFunc func(config *ic.InstallConfig) (cmd string, err error)) error {
	args := m.Called(kind, cmd, buildCmdFunc)

	return args.Error(0)
}

type mockTzConfigWorkspaceHandle struct {
	mock.Mock
}

func (m *mockTzConfigWorkspaceHandle) Release() error {
	args := m.Called()
	return args.Error(0)
}

func SetupTimezoneConfigMock() {
	mockTimezoneConfigWorkspaceHandle := &mockTzConfigWorkspaceHandle{}
	mockTimezoneConfigWorkspaceHandle.On(r.GetFunctionName(mockTimezoneConfigWorkspaceHandle.Release)).Return(nil)

	createTzHandleFunc = func() (tz.ConfigWorkspaceHandle, error) {
		return mockTimezoneConfigWorkspaceHandle, nil
	}
}

func TestInstall(t *testing.T) {
	RegisterFailHandler(Fail)
	SetupTimezoneConfigMock()
	RunSpecs(t, "install Unit Tests", Label("unit", "ci"))
}

var _ = Describe("install", func() {
	Describe("install", func() {
		When("error while receiving Linux-only flag value occurred", func() {
			It("returns error", func() {
				cmd := &cobra.Command{}

				Expect(install(cmd, nil)).ToNot(Succeed())
			})
		})

		When("not Linux-only", func() {
			It("calls installer", func() {
				cmd := &cobra.Command{}
				flags := cmd.Flags()
				flags.Bool(ic.LinuxOnlyFlagName, false, "")

				installerMock := &mockObject{}
				installerMock.On(r.GetFunctionName(installerMock.Install), kind, cmd, mock.AnythingOfType("func(*config.InstallConfig) (string, error)")).Return(nil).Once()

				installer = installerMock

				Expect(install(cmd, nil)).To(Succeed())

				installerMock.AssertExpectations(GinkgoT())
			})
		})

		When("Linux-only", func() {
			It("calls multivm installer", func() {
				cmd := &cobra.Command{}
				flags := cmd.Flags()
				flags.Bool(ic.LinuxOnlyFlagName, true, "")
				args := []string{"test"}
				installMultiVmCalled := false

				installMultiVmFunc = func(c *cobra.Command, a []string) error {
					installMultiVmCalled = cmd == c && a[0] == "test"
					return nil
				}

				Expect(install(cmd, args)).To(Succeed())

				Expect(installMultiVmCalled).To(BeTrue())
			})
		})
	})

	Describe("buildInstallCmd", func() {
		When("node is missing", func() {
			It("returns an error", func() {
				config := &ic.InstallConfig{}

				actual, err := buildInstallCmd(config)

				Expect(actual).To(BeEmpty())
				Expect(err).To(MatchError(ContainSubstring("not found")))
			})
		})

		Context("without switches", func() {
			It("returns correct command", func() {
				const staticPartOfExpectedCmd = `\lib\scripts\k2s\install\install.ps1' -MasterVMProcessorCount 5 -MasterVMMemory 6GB -MasterDiskSize 7GB`
				expected := "&'" + utils.InstallDir() + staticPartOfExpectedCmd

				config := &ic.InstallConfig{
					Nodes: []ic.NodeConfig{{
						Role: ic.ControlPlaneRoleName,
						Resources: ic.ResourceConfig{
							Cpu:    "5",
							Memory: "6GB",
							Disk:   "7GB",
						}}},
				}

				actual, err := buildInstallCmd(config)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})

		Context("with all switches", func() {
			It("returns correct command", func() {
				const staticPartOfExpectedCmd = `\lib\scripts\k2s\install\install.ps1' -MasterVMProcessorCount 5 -MasterVMMemory 6GB -MasterDiskSize 7GB` +
					` -Proxy my_proxy -AdditionalHooksDir 'c:\hooks\dir' -RestartAfterInstallCount 123 -K8sBinsPath 'c:\k8sBins\dir' -ShowLogs -SkipStart -DeleteFilesForOfflineInstallation -ForceOnlineInstallation -WSL -AppendLogFile`
				expected := "&'" + utils.InstallDir() + staticPartOfExpectedCmd

				config := &ic.InstallConfig{
					Env: ic.EnvConfig{
						Proxy:              "my_proxy",
						AdditionalHooksDir: "c:\\hooks\\dir",
						RestartPostInstall: "123",
						K8sBins:            "c:\\k8sBins\\dir",
					},
					Behavior: ic.BehaviorConfig{
						ShowOutput:                        true,
						DeleteFilesForOfflineInstallation: true,
						ForceOnlineInstallation:           true,
						Wsl:                               true,
						AppendLog:                         true,
						SkipStart:                         true,
					},
					Nodes: []ic.NodeConfig{{
						Role: ic.ControlPlaneRoleName,
						Resources: ic.ResourceConfig{
							Cpu:    "5",
							Memory: "6GB",
							Disk:   "7GB",
						}}},
				}

				actual, err := buildInstallCmd(config)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})
	})
})
