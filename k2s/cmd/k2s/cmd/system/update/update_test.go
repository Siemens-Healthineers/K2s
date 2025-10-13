// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package update

import (
    "testing"
    "path/filepath"

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

        When("delta package flag provided", func() {
            It("appends -DeltaPackage argument", func() {
                const scriptRel = "lib/scripts/k2s/system/update/Start-ClusterUpdate.ps1"
                deltaPath := "C:/temp/k2s-delta-1.0.0-to-1.1.0.zip"
                expected := utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), scriptRel)) + " -DeltaPackage " + deltaPath

                // set the -f / --delta-package flag
                UpdateCmd.Flags().Set(deltaPackageFlagName, deltaPath)
                // cleanup after test to avoid leakage into following specs
                DeferCleanup(func() { UpdateCmd.Flags().Set(deltaPackageFlagName, "") })

                actual := createUpdateCommand(UpdateCmd)
                Expect(actual).To(Equal(expected))
            })
        })
    })
})
