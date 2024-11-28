// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package upgrade

import (
	"testing"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestUpgrade(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "upgrade Unit Tests", Label("unit", "ci"))
}

var _ = BeforeSuite(func() {
	UpgradeCmd.Flags().BoolP(common.OutputFlagName, common.OutputFlagShorthand, false, common.OutputFlagUsage)
})

var _ = Describe("upgrade", func() {
	Describe("createUpgradeCommand", func() {
		When("no flags set", func() {
			It("creates the command", func() {
				const staticPartOfExpectedCmd = `\lib\scripts\k2s\system\upgrade\Start-ClusterUpgrade.ps1`
				expected := utils.FormatScriptFilePath(utils.InstallDir() + staticPartOfExpectedCmd)

				actual := createUpgradeCommand(UpgradeCmd)

				Expect(actual).To(Equal(expected))
			})
		})

		When("flags set", func() {
			It("creates the command", func() {
				const staticPartOfExpectedCmd = `\lib\scripts\k2s\system\upgrade\Start-ClusterUpgrade.ps1`
				const args = ` -ShowLogs -SkipResources  -DeleteFiles  -Config config.yaml -Proxy http://myproxy:81 -SkipImages -AdditionalHooksDir 'hookDir' -BackupDir 'backupDir'`
				expected := utils.FormatScriptFilePath(utils.InstallDir()+staticPartOfExpectedCmd) + args

				flags := UpgradeCmd.Flags()
				flags.Set(common.OutputFlagName, "true")
				flags.Set(skipK8sResources, "true")
				flags.Set(deleteFiles, "true")
				flags.Set(configFileFlagName, "config.yaml")
				flags.Set(proxy, "http://myproxy:81")
				flags.Set(skipImages, "true")
				flags.Set(common.AdditionalHooksDirFlagName, "hookDir")
				flags.Set(backupDir, "backupDir")

				actual := createUpgradeCommand(UpgradeCmd)

				Expect(actual).To(Equal(expected))
			})
		})
	})
})
