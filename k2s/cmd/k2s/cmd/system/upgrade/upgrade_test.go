// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package upgrade

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	"github.com/siemens-healthineers/k2s/internal/definitions"

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

// Helper function to reset all flags to their default values
func resetAllFlags() {
	flags := UpgradeCmd.Flags()
	flags.Set(common.OutputFlagName, "false")
	flags.Set(skipK8sResources, "false")
	flags.Set(deleteFiles, "false")
	flags.Set(configFileFlagName, "")
	flags.Set(proxy, "")
	flags.Set(skipImagesFlag, "false")
	flags.Set(common.AdditionalHooksDirFlagName, "")
	flags.Set(backupDir, "")
	flags.Set(force, "false")
}

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
				flags.Set(skipImagesFlag, "true")
				flags.Set(common.AdditionalHooksDirFlagName, "hookDir")
				flags.Set(backupDir, "backupDir")

				actual := createUpgradeCommand(UpgradeCmd)

				Expect(actual).To(Equal(expected))
			})
		})

		When("force flag is set", func() {
			It("creates the command with force flag", func() {
				const staticPartOfExpectedCmd = `\lib\scripts\k2s\system\upgrade\Start-ClusterUpgrade.ps1`
				const args = ` -Force`
				expected := utils.FormatScriptFilePath(utils.InstallDir()+staticPartOfExpectedCmd) + args

				// Reset all flags to default values
				resetAllFlags()
				// Set only the flag under test
				UpgradeCmd.Flags().Set(force, "true")

				actual := createUpgradeCommand(UpgradeCmd)

				Expect(actual).To(Equal(expected))
			})
		})
	})

	Describe("applySetupConfigDirOverride", func() {
		var packageInstallDir string
		var packageConfigFile string
		var originalConfigContent []byte

		// realistic package config file; it must never be touched by the upgrade.
		const packageConfigJson = `{
  "smallsetup": { "masterIP": "172.19.1.100" },
  "clusterName": "k2s-cluster",
  "configDir": {
    "kube": "~/.kube",
    "k2s": "C:\\ProgramData\\K2s",
    "ssh": "~/.ssh",
    "docker": "~/.docker",
    "logs": "C:\\var\\log"
  }
}`

		BeforeEach(func() {
			// isolate the env var per spec
			GinkgoT().Setenv(definitions.SetupConfigDirEnvVar, "")
			Expect(os.Unsetenv(definitions.SetupConfigDirEnvVar)).To(Succeed())

			packageInstallDir = GinkgoT().TempDir()
			Expect(os.MkdirAll(filepath.Join(packageInstallDir, "cfg"), os.ModePerm)).To(Succeed())
			packageConfigFile = filepath.Join(packageInstallDir, "cfg", "config.json")
			Expect(os.WriteFile(packageConfigFile, []byte(packageConfigJson), os.ModePerm)).To(Succeed())

			var err error
			originalConfigContent, err = os.ReadFile(packageConfigFile)
			Expect(err).ToNot(HaveOccurred())
		})

		// The package's config file is the source of truth of the NEW installation and
		// must never be modified by the upgrade.
		AfterEach(func() {
			currentContent, err := os.ReadFile(packageConfigFile)
			Expect(err).ToNot(HaveOccurred())
			Expect(currentContent).To(Equal(originalConfigContent), "the package's cfg/config.json must never be modified")

			var parsed map[string]any
			Expect(json.Unmarshal(currentContent, &parsed)).To(Succeed())
			Expect(parsed["configDir"].(map[string]any)["k2s"]).To(Equal(`C:\ProgramData\K2s`))
		})

		When("the old installation uses a custom config dir and the package uses the default one", func() {
			It("sets the override to the old config dir", func() {
				err := applySetupConfigDirOverride(`C:\DummySetup\K2s`, `C:\ProgramData\K2s`)

				Expect(err).ToNot(HaveOccurred())
				Expect(os.Getenv(definitions.SetupConfigDirEnvVar)).To(Equal(`C:\DummySetup\K2s`))
			})
		})

		When("the old installation and the package both use the default config dir", func() {
			It("does not set the override", func() {
				err := applySetupConfigDirOverride(`C:\ProgramData\K2s`, `C:\ProgramData\K2s`)

				Expect(err).ToNot(HaveOccurred())

				_, isSet := os.LookupEnv(definitions.SetupConfigDirEnvVar)
				Expect(isSet).To(BeFalse())
			})
		})

		When("the old installation uses a custom config dir and the package uses a different custom one", func() {
			It("sets the override to the old config dir", func() {
				err := applySetupConfigDirOverride(`C:\DummySetup\K2s`, `D:\CustomPkg\K2s`)

				Expect(err).ToNot(HaveOccurred())
				Expect(os.Getenv(definitions.SetupConfigDirEnvVar)).To(Equal(`C:\DummySetup\K2s`))
			})
		})

		When("no config dir could be resolved", func() {
			It("does not set the override", func() {
				err := applySetupConfigDirOverride("", `C:\ProgramData\K2s`)

				Expect(err).ToNot(HaveOccurred())

				_, isSet := os.LookupEnv(definitions.SetupConfigDirEnvVar)
				Expect(isSet).To(BeFalse())
			})
		})
	})
})
