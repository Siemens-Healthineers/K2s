// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
// SPDX-License-Identifier: MIT

package backup

import (
	"testing"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestBackup(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "backup Unit Tests", Label("unit", "ci"))
}

var _ = BeforeSuite(func() {
	SystemBackupCmd.Flags().BoolP(
		common.OutputFlagName,
		common.OutputFlagShorthand,
		false,
		common.OutputFlagUsage,
	)
})

// Reset flags helper (same pattern as upgrade)
func resetBackupFlags() {
	flags := SystemBackupCmd.Flags()
	flags.Set(common.OutputFlagName, "false")
	flags.Set(backupFileFlag, "")
	flags.Set(common.AdditionalHooksDirFlagName, "")
}

var _ = Describe("backup", func() {

	Describe("createSystemBackupPsCommand", func() {

		When("only mandatory flags are set", func() {
			It("creates minimal backup command", func() {
				const staticPart = `\lib\scripts\k2s\system\backup\Start-SystemBackup.ps1`
				const args = ` -BackupFile 'C:\temp\backup.zip'`

				expected := utils.FormatScriptFilePath(
					utils.InstallDir()+staticPart,
				) + args

				resetBackupFlags()
				SystemBackupCmd.Flags().Set(backupFileFlag, `C:\temp\backup.zip`)

				actual := createSystemBackupPsCommand(SystemBackupCmd)

				Expect(actual).To(Equal(expected))
			})
		})

		When("show logs flag is enabled", func() {
			It("adds -ShowLogs to command", func() {
				const staticPart = `\lib\scripts\k2s\system\backup\Start-SystemBackup.ps1`
				const args = ` -ShowLogs -BackupFile 'C:\temp\backup.zip'`

				expected := utils.FormatScriptFilePath(
					utils.InstallDir()+staticPart,
				) + args

				resetBackupFlags()
				flags := SystemBackupCmd.Flags()
				flags.Set(common.OutputFlagName, "true")
				flags.Set(backupFileFlag, `C:\temp\backup.zip`)

				actual := createSystemBackupPsCommand(SystemBackupCmd)

				Expect(actual).To(Equal(expected))
			})
		})

		When("additional hooks directory is provided", func() {
			It("adds -AdditionalHooksDir to command", func() {
				const staticPart = `\lib\scripts\k2s\system\backup\Start-SystemBackup.ps1`
				const args = ` -BackupFile 'C:\temp\backup.zip' -AdditionalHooksDir 'hooksDir'`

				expected := utils.FormatScriptFilePath(
					utils.InstallDir()+staticPart,
				) + args

				resetBackupFlags()
				flags := SystemBackupCmd.Flags()
				flags.Set(backupFileFlag, `C:\temp\backup.zip`)
				flags.Set(common.AdditionalHooksDirFlagName, "hooksDir")

				actual := createSystemBackupPsCommand(SystemBackupCmd)

				Expect(actual).To(Equal(expected))
			})
		})
	})
})
