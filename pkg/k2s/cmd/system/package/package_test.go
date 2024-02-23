// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package systempackage

import (
	p "k2s/cmd/params"
	"k2s/utils"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestUpgrade(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "package Unit Tests", Label("unit"))
}

var _ = BeforeSuite(func() {
	PackageCmd.Flags().BoolP(p.OutputFlagName, p.OutputFlagShorthand, false, p.OutputFlagUsage)
})

var _ = Describe("package", func() {
	Describe("buildSystemPackageCmd", func() {
		When("flags set", func() {
			It("creates the command", func() {
				const staticPartOfExpectedCmd = `\smallsetup\helpers\BuildK2sZipPackage.ps1' -ShowLogs -Proxy http://myproxy:81 -VMProcessorCount 6 -VMMemoryStartupBytes 4GB -VMDiskSize 50GB -TargetDirectory 'dir' -ZipPackageFileName file.zip -ForOfflineInstallation`
				expected := "&'" + utils.GetInstallationDirectory() + staticPartOfExpectedCmd

				flags := PackageCmd.Flags()
				flags.Set(p.OutputFlagName, "true")
				flags.Set(ControlPlaneCPUsFlagName, "6")
				flags.Set(ControlPlaneMemoryFlagName, "4GB")
				flags.Set(ControlPlaneDiskSizeFlagName, "50GB")
				flags.Set(TargetDirectoryFlagName, "dir")
				flags.Set(ZipPackageFileNameFlagName, "file.zip")
				flags.Set(ProxyFlagName, "http://myproxy:81")
				flags.Set(ForOfflineInstallationFlagName, "true")

				actual, err := buildSystemPackageCmd(PackageCmd)
				Expect(err).To(BeNil())

				Expect(actual).To(Equal(expected))
			})
		})

		When("when target dir is empty", func() {
			It("throws", func() {
				flags := PackageCmd.Flags()
				flags.Set(TargetDirectoryFlagName, "")

				_, err := buildSystemPackageCmd(PackageCmd)
				Expect(err).ToNot(BeNil())
				Expect(err.Error()).To(Equal("no target directory path provided"))
			})
		})

		When("when package name is empty", func() {
			It("throws", func() {
				flags := PackageCmd.Flags()
				flags.Set(ZipPackageFileNameFlagName, "")
				flags.Set(TargetDirectoryFlagName, "dir")

				_, err := buildSystemPackageCmd(PackageCmd)
				Expect(err).ToNot(BeNil())
				Expect(err.Error()).To(Equal("no package file name provided"))
			})
		})

		When("when package name does not container '.zip'", func() {
			It("throws", func() {
				flags := PackageCmd.Flags()
				flags.Set(TargetDirectoryFlagName, "dir")
				flags.Set(ZipPackageFileNameFlagName, "file")

				_, err := buildSystemPackageCmd(PackageCmd)
				Expect(err).ToNot(BeNil())
				Expect(err.Error()).To(Equal("package file name does not contain '.zip'"))
			})
		})
	})
})
