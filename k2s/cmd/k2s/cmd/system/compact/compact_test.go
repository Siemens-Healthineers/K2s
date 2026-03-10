// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
// SPDX-License-Identifier: MIT

package compact

import (
	"path/filepath"
	"testing"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestCompact(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "compact Unit Tests", Label("unit", "ci", "compact"))
}

// resetCompactFlags resets all package-level flag variables and the OutputFlag between tests.
func resetCompactFlags() {
	noRestartFlag = false
	yesFlag = false
	CompactCmd.Flags().Set(common.OutputFlagName, "false")
}

var _ = BeforeSuite(func() {
	// Register the output flag once so all tests can manipulate it.
	CompactCmd.Flags().BoolP(
		common.OutputFlagName,
		common.OutputFlagShorthand,
		false,
		common.OutputFlagUsage,
	)
})

var _ = Describe("compact", func() {

	Describe("buildCompactCmd", func() {

		BeforeEach(func() {
			resetCompactFlags()
		})

		When("no optional flags are set", func() {
			It("returns a command containing only the script path", func() {
				const staticPart = `\lib\scripts\k2s\system\compact\Invoke-VhdxCompaction.ps1`
				expected := utils.FormatScriptFilePath(utils.InstallDir() + staticPart)

				actual, err := buildCompactCmd(false)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})

		When("show-logs (output) flag is set", func() {
			It("appends -ShowLogs to the command", func() {
				const staticPart = `\lib\scripts\k2s\system\compact\Invoke-VhdxCompaction.ps1`
				expected := utils.FormatScriptFilePath(utils.InstallDir()+staticPart) + " -ShowLogs"

				actual, err := buildCompactCmd(true)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})

		When("no-restart flag is set", func() {
			It("appends -NoRestart to the command", func() {
				const staticPart = `\lib\scripts\k2s\system\compact\Invoke-VhdxCompaction.ps1`
				expected := utils.FormatScriptFilePath(utils.InstallDir()+staticPart) + " -NoRestart"

				noRestartFlag = true
				actual, err := buildCompactCmd(false)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})

		When("yes flag is set", func() {
			It("appends -Yes to the command", func() {
				const staticPart = `\lib\scripts\k2s\system\compact\Invoke-VhdxCompaction.ps1`
				expected := utils.FormatScriptFilePath(utils.InstallDir()+staticPart) + " -Yes"

				yesFlag = true
				actual, err := buildCompactCmd(false)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})

		When("all flags are set", func() {
			It("appends all parameters in the correct order", func() {
				const staticPart = `\lib\scripts\k2s\system\compact\Invoke-VhdxCompaction.ps1`
				expected := utils.FormatScriptFilePath(utils.InstallDir()+staticPart) +
					" -NoRestart -Yes -ShowLogs"

				noRestartFlag = true
				yesFlag = true
				actual, err := buildCompactCmd(true)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})

		When("no-restart and show-logs flags are set", func() {
			It("appends both parameters", func() {
				const staticPart = `\lib\scripts\k2s\system\compact\Invoke-VhdxCompaction.ps1`
				expected := utils.FormatScriptFilePath(utils.InstallDir()+staticPart) +
					" -NoRestart -ShowLogs"

				noRestartFlag = true
				actual, err := buildCompactCmd(true)


				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})

		It("always references Invoke-VhdxCompaction.ps1 inside the compact subfolder", func() {
			actual, err := buildCompactCmd(false)

			Expect(err).ToNot(HaveOccurred())
			Expect(actual).To(ContainSubstring(filepath.Join("lib", "scripts", "k2s", "system", "compact", "Invoke-VhdxCompaction.ps1")))
		})
	})
})

