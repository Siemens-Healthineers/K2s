// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package buildonly

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

func TestBuildOnly(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "buildonly Unit Tests", Label("unit", "ci"))
}

var _ = Describe("buildonly", func() {
	Describe("install", func() {
		It("calls installer correctly", func() {
			cmd := &cobra.Command{}

			installerMock := &mockObject{}
			installerMock.On(r.GetFunctionName(installerMock.Install), ic.Kind(kind), cmd, mock.AnythingOfType("func(*config.InstallConfig) (string, error)")).Return(nil).Once()

			Installer = installerMock

			Expect(install(cmd, nil)).To(Succeed())

			installerMock.AssertExpectations(GinkgoT())
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
			It("returns expected command", func() {
				const staticPartOfExpectedCmd = `\lib\scripts\buildonly\install\install.ps1' -MasterVMProcessorCount 5 -MasterVMMemory 6GB -MasterDiskSize 7GB`
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
			It("returns expected command", func() {
				const staticPartOfExpectedCmd = `\lib\scripts\buildonly\install\install.ps1' -MasterVMProcessorCount 5 -MasterVMMemory 6GB -MasterDiskSize 7GB` +
					` -Proxy my_proxy -ShowLogs -DeleteFilesForOfflineInstallation -ForceOnlineInstallation -WSL -AppendLogFile`
				expected := "&'" + utils.InstallDir() + staticPartOfExpectedCmd

				config := &ic.InstallConfig{
					Env: ic.EnvConfig{Proxy: "my_proxy"},
					Behavior: ic.BehaviorConfig{
						ShowOutput:                        true,
						DeleteFilesForOfflineInstallation: true,
						ForceOnlineInstallation:           true,
						Wsl:                               true,
						AppendLog:                         true,
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
