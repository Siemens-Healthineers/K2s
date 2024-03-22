// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package multivm

import (
	"testing"

	ic "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/install/config"

	r "github.com/siemens-healthineers/k2s/internal/reflection"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

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

func TestMultivm(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "multivm Unit Tests", Label("unit", "ci"))
}

var _ = Describe("multivm", func() {
	Describe("Install", func() {
		It("calls installer", func() {
			cmd := &cobra.Command{}

			installerMock := &mockObject{}
			installerMock.On(r.GetFunctionName(installerMock.Install), ic.Kind(kind), cmd, mock.AnythingOfType("func(*config.InstallConfig) (string, error)")).Return(nil).Once()

			Installer = installerMock

			Expect(Install(cmd, nil)).To(Succeed())

			installerMock.AssertExpectations(GinkgoT())
		})
	})

	Describe("buildInstallCmd", func() {
		When("WSL is enabled", func() {
			It("returns an error", func() {
				config := &ic.InstallConfig{Behavior: ic.BehaviorConfig{Wsl: true}}

				actual, err := buildInstallCmd(config)

				Expect(actual).To(BeEmpty())
				Expect(err).To(MatchError(ContainSubstring("not supported")))
			})
		})

		When("control-plane node is missing", func() {
			It("returns an error", func() {
				config := &ic.InstallConfig{
					Nodes: []ic.NodeConfig{{Role: ic.WorkerRoleName}},
				}

				actual, err := buildInstallCmd(config)

				Expect(actual).To(BeEmpty())
				Expect(err).To(MatchError(ContainSubstring("not found")))
			})
		})

		When("worker node is missing", func() {
			It("returns an error", func() {
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

				Expect(actual).To(BeEmpty())
				Expect(err).To(MatchError(ContainSubstring("not found")))
			})
		})

		Context("Linux-only without additional switches", func() {
			It("returns command", func() {
				const staticPartOfExpectedCmd = `\smallsetup\multivm\Install_MultiVMK8sSetup.ps1' -MasterVMProcessorCount 5 -MasterVMMemory 6GB -MasterDiskSize 7GB -LinuxOnly`
				expected := "&'" + utils.InstallDir() + staticPartOfExpectedCmd

				config := &ic.InstallConfig{
					Nodes: []ic.NodeConfig{{
						Role: ic.ControlPlaneRoleName,
						Resources: ic.ResourceConfig{
							Cpu:    "5",
							Memory: "6GB",
							Disk:   "7GB",
						}}},
					LinuxOnly: true,
				}

				actual, err := buildInstallCmd(config)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})

		Context("Linux-only with additional switches", func() {
			It("returns command", func() {
				const staticPartOfExpectedCmd = `\smallsetup\multivm\Install_MultiVMK8sSetup.ps1' -MasterVMProcessorCount 5 -MasterVMMemory 6GB -MasterDiskSize 7GB -LinuxOnly` +
					` -Proxy my_proxy -AdditionalHooksDir 'c:\my\dir' -ShowLogs -SkipStart -DeleteFilesForOfflineInstallation -ForceOnlineInstallation -AppendLogFile`
				expected := "&'" + utils.InstallDir() + staticPartOfExpectedCmd

				config := &ic.InstallConfig{
					Nodes: []ic.NodeConfig{{
						Role: ic.ControlPlaneRoleName,
						Resources: ic.ResourceConfig{
							Cpu:    "5",
							Memory: "6GB",
							Disk:   "7GB",
						}}},
					LinuxOnly: true,
					Env: ic.EnvConfig{
						Proxy:              "my_proxy",
						AdditionalHooksDir: "c:\\my\\dir",
					},
					Behavior: ic.BehaviorConfig{
						ShowOutput:                        true,
						DeleteFilesForOfflineInstallation: true,
						ForceOnlineInstallation:           true,
						AppendLog:                         true,
						SkipStart:                         true,
					},
				}

				actual, err := buildInstallCmd(config)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})

		Context("image param is not set", func() {
			It("returns error", func() {
				config := &ic.InstallConfig{
					Nodes: []ic.NodeConfig{
						{
							Role: ic.ControlPlaneRoleName,
							Resources: ic.ResourceConfig{
								Cpu:    "5",
								Memory: "6GB",
								Disk:   "7GB",
							}},
						{
							Role: ic.WorkerRoleName,
							Resources: ic.ResourceConfig{
								Cpu:    "8",
								Memory: "9GB",
								Disk:   "10GB",
							},
						}},
				}

				actual, err := buildInstallCmd(config)

				Expect(err).To(MatchError(ContainSubstring("missing flag '--image'")))
				Expect(actual).To(BeEmpty())
			})
		})

		Context("without additional switches", func() {
			It("returns command", func() {
				const staticPartOfExpectedCmd = `\smallsetup\multivm\Install_MultiVMK8sSetup.ps1' -MasterVMProcessorCount 5 -MasterVMMemory 6GB -MasterDiskSize 7GB` +
					` -WinVMProcessorCount 8 -WinVMStartUpMemory 9GB -WinVMDiskSize 10GB -WindowsImage c:\path\to\image.file`
				expected := "&'" + utils.InstallDir() + staticPartOfExpectedCmd

				config := &ic.InstallConfig{
					Nodes: []ic.NodeConfig{
						{
							Role: ic.ControlPlaneRoleName,
							Resources: ic.ResourceConfig{
								Cpu:    "5",
								Memory: "6GB",
								Disk:   "7GB",
							}},
						{
							Role: ic.WorkerRoleName,
							Resources: ic.ResourceConfig{
								Cpu:    "8",
								Memory: "9GB",
								Disk:   "10GB",
							},
							Image: "c:\\path\\to\\image.file",
						}},
				}

				actual, err := buildInstallCmd(config)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})

		Context("with additional switches", func() {
			It("returns command", func() {
				const staticPartOfExpectedCmd = `\smallsetup\multivm\Install_MultiVMK8sSetup.ps1' -MasterVMProcessorCount 5 -MasterVMMemory 6GB -MasterDiskSize 7GB` +
					` -WinVMProcessorCount 8 -WinVMStartUpMemory 9GB -WinVMDiskSize 10GB -WindowsImage c:\path\to\image.file` +
					` -Proxy my_proxy -AdditionalHooksDir 'c:\my\dir' -ShowLogs -SkipStart -DeleteFilesForOfflineInstallation -ForceOnlineInstallation -AppendLogFile`
				expected := "&'" + utils.InstallDir() + staticPartOfExpectedCmd

				config := &ic.InstallConfig{
					Nodes: []ic.NodeConfig{
						{
							Role: ic.ControlPlaneRoleName,
							Resources: ic.ResourceConfig{
								Cpu:    "5",
								Memory: "6GB",
								Disk:   "7GB",
							}},
						{
							Role: ic.WorkerRoleName,
							Resources: ic.ResourceConfig{
								Cpu:    "8",
								Memory: "9GB",
								Disk:   "10GB",
							},
							Image: "c:\\path\\to\\image.file",
						}},
					Env: ic.EnvConfig{
						Proxy:              "my_proxy",
						AdditionalHooksDir: "c:\\my\\dir",
					},
					Behavior: ic.BehaviorConfig{
						ShowOutput:                        true,
						DeleteFilesForOfflineInstallation: true,
						ForceOnlineInstallation:           true,
						AppendLog:                         true,
						SkipStart:                         true,
					},
				}

				actual, err := buildInstallCmd(config)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})
	})
})
