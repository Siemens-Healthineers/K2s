// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package upgrade

import (
	"testing"

	p "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/params"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestUpgrade(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "upgrade Unit Tests", Label("unit", "ci"))
}

var _ = BeforeSuite(func() {
	UpgradeCmd.Flags().BoolP(p.OutputFlagName, p.OutputFlagShorthand, false, p.OutputFlagUsage)
})

var _ = Describe("upgrade", func() {
	Describe("createUpgradeCommand", func() {
		When("no flags set", func() {
			It("creates the command", func() {
				const staticPartOfExpectedCmd = `\smallsetup\upgrade\Start-ClusterUpgrade.ps1`
				expected := utils.InstallDir() + staticPartOfExpectedCmd

				actual := createUpgradeCommand(UpgradeCmd)

				Expect(actual).To(Equal(expected))
			})
		})

		When("flags set", func() {
			It("creates the command", func() {
				const staticPartOfExpectedCmd = `\smallsetup\upgrade\Start-ClusterUpgrade.ps1 -ShowLogs -SkipResources  -DeleteFiles  -Config config.yaml -Proxy http://myproxy:81 -SkipImages `
				expected := utils.InstallDir() + staticPartOfExpectedCmd

				flags := UpgradeCmd.Flags()
				flags.Set(p.OutputFlagName, "true")
				flags.Set(skipK8sResources, "true")
				flags.Set(deleteFiles, "true")
				flags.Set(configFileFlagName, "config.yaml")
				flags.Set(proxy, "http://myproxy:81")
				flags.Set(skipImages, "true")

				actual := createUpgradeCommand(UpgradeCmd)

				Expect(actual).To(Equal(expected))
			})
		})
	})
})
