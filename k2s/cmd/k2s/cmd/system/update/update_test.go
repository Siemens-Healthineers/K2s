// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package update

import (
	"path/filepath"
	"testing"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestUpdate(t *testing.T) {
    RegisterFailHandler(Fail)
    RunSpecs(t, "update Unit Tests", Label("unit", "ci"))
}

var _ = Describe("update", func() {
    Describe("createUpdateCommand", func() {
        When("no flags set", func() {
            It("creates the base PowerShell command", func() {
                const scriptRel = "lib/scripts/k2s/system/update/Start-ClusterUpdate.ps1"
                expected := utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), scriptRel))

                actual := createUpdateCommand(UpdateCmd)
                Expect(actual).To(Equal(expected))
            })
        })

        // Delta package parameter removed - update command now detects delta from current directory
    })
})
